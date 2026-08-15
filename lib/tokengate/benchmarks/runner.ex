defmodule Tokengate.Benchmarks.Runner do
  @moduledoc """
  Provider benchmark runner — measures TTFT, TPS, latency and token count
  for one or more LLM providers using the same prompt.

  Each target is an OpenAI-compatible endpoint. The runner sends a streaming
  chat completion request and measures:

    * **TTFT** (time to first token) — from request start to first SSE chunk.
    * **Total time** — from request start to stream end.
    * **Tokens generated** — from the `usage` object in the final chunk,
      falling back to counting delta chunks.
    * **TPS** (tokens per second) — tokens / (total_time - ttft), the
      generation throughput excluding initial latency.
    * **Latency** — total end-to-end time.

  All measurements are in milliseconds except TPS (tokens/sec).

  Uses `Tokengate.Finch` for HTTP — same pool as the proxy.
  """

  alias Tokengate.Benchmarks.Target

  @default_receive_timeout 120_000
  @default_max_tokens 256

  @doc """
  Runs a benchmark across multiple targets in parallel.

  Returns a list of `%Target{}` structs with results filled in.

  ## Options

    * `:max_tokens` — max tokens to generate (default #{@default_max_tokens})
    * `:receive_timeout` — HTTP timeout in ms (default #{@default_receive_timeout})
    * `:runs` — number of runs per target to average (default 1)
  """
  def run(targets, prompt, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    runs = Keyword.get(opts, :runs, 1)

    targets
    |> Task.async_stream(
      fn target -> measure_target(target, prompt, max_tokens, receive_timeout, runs) end,
      timeout: receive_timeout + 10_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(targets)
    |> Enum.map(fn
      {:ok, result}, _target -> result
      {:exit, :timeout}, target -> Target.error(target, "Timeout")
      {:exit, reason}, target -> Target.error(target, "Crashed: #{inspect(reason)}")
    end)
  end

  defp measure_target(target, prompt, max_tokens, receive_timeout, runs) do
    results =
      1..runs
      |> Enum.map(fn _ -> single_run(target, prompt, max_tokens, receive_timeout) end)

    aggregate_results(target, results)
  end

  defp single_run(target, prompt, max_tokens, receive_timeout) do
    url = build_url(target.base_url, "/chat/completions")

    payload =
      %{
        "model" => target.model,
        "messages" => [%{"role" => "user", "content" => prompt}],
        "stream" => true,
        "stream_options" => %{"include_usage" => true},
        "max_tokens" => max_tokens
      }

    body = Jason.encode!(payload)

    request =
      Finch.build(:post, url, headers(target.api_key), body)

    start_ms = System.monotonic_time(:millisecond)

    case stream_and_measure(request, start_ms, receive_timeout) do
      {:ok, measurements} -> measurements
      {:error, reason} -> %{error: reason}
    end
  end

  defp stream_and_measure(request, start_ms, receive_timeout) do
    acc = %{
      start_ms: start_ms,
      ttft_ms: nil,
      first_chunk_at: nil,
      token_count: 0,
      chunk_count: 0,
      usage_tokens: nil,
      done: false,
      buffer: "",
      error: nil
    }

    result =
      Finch.stream_while(
        request,
        Tokengate.Finch,
        acc,
        fn entry, acc ->
          case entry do
            {:status, status} ->
              if status in 200..299 do
                {:cont, acc}
              else
                {:halt, %{acc | error: "HTTP #{status}"}}
              end

            {:headers, _headers} ->
              {:cont, acc}

            {:data, data} ->
              process_sse_data(data, acc)

            {:trailers, _} ->
              {:cont, acc}
          end
        end,
        receive_timeout: receive_timeout
      )

    case result do
      {:ok, %{error: error}} when not is_nil(error) ->
        {:error, error}

      {:ok, acc} ->
        total_ms = System.monotonic_time(:millisecond) - acc.start_ms
        tokens = acc.usage_tokens || acc.chunk_count

        ttft = acc.ttft_ms || total_ms
        gen_time_ms = max(total_ms - ttft, 1)
        tps = if tokens > 0, do: tokens / (gen_time_ms / 1000.0), else: 0.0

        {:ok,
         %{
           ttft_ms: ttft,
           total_ms: total_ms,
           tokens: tokens,
           tps: Float.round(tps, 2)
         }}

      {:error, error, _acc} ->
        {:error, format_error(error)}
    end
  end

  defp process_sse_data(data, acc) do
    buffer = acc.buffer <> data
    {events, rest} = split_events(buffer)
    acc = %{acc | buffer: rest}

    Enum.reduce_while(events, acc, fn event, acc ->
      case handle_sse_event(event, acc) do
        {:cont, acc} -> {:cont, acc}
        {:halt, acc} -> {:halt, acc}
      end
    end)
    |> case do
      {:halt, acc} -> {:halt, acc}
      acc -> {:cont, acc}
    end
  end

  defp handle_sse_event(event, acc) do
    data_lines =
      event
      |> String.split("\n", trim: true)
      |> Enum.filter(&data_line?/1)
      |> Enum.map(&extract_data/1)

    case data_lines do
      [] ->
        {:cont, acc}

      lines ->
        data = Enum.join(lines, "\n")
        trimmed = String.trim(data)

        cond do
          trimmed == "[DONE]" ->
            {:halt, %{acc | done: true}}

          trimmed == "" ->
            {:cont, acc}

          true ->
            now = System.monotonic_time(:millisecond)

            acc =
              if is_nil(acc.first_chunk_at) do
                %{acc | first_chunk_at: now, ttft_ms: now - acc.start_ms}
              else
                acc
              end

            case Jason.decode(trimmed) do
              {:ok, chunk} ->
                acc = count_delta_tokens(acc, chunk)
                acc = extract_usage(acc, chunk)
                {:cont, acc}

              {:error, _} ->
                {:cont, %{acc | chunk_count: acc.chunk_count + 1}}
            end
        end
    end
  end

  defp count_delta_tokens(acc, %{"choices" => choices}) when is_list(choices) do
    deltas =
      Enum.count(choices, fn
        %{"delta" => %{"content" => c}} when is_binary(c) and byte_size(c) > 0 -> true
        %{"delta" => %{"reasoning_content" => r}} when is_binary(r) and byte_size(r) > 0 -> true
        _ -> false
      end)

    {:cont, %{acc | chunk_count: acc.chunk_count + deltas}}
  end

  defp count_delta_tokens(acc, _chunk), do: acc

  defp extract_usage(acc, %{"usage" => usage}) when is_map(usage) do
    completion_tokens = Map.get(usage, "completion_tokens") || Map.get(usage, "output_tokens")

    if completion_tokens && is_integer(completion_tokens) && completion_tokens > 0 do
      %{acc | usage_tokens: completion_tokens}
    else
      acc
    end
  end

  defp extract_usage(acc, _chunk), do: acc

  defp aggregate_results(target, results) do
    valid = Enum.reject(results, &Map.has_key?(&1, :error))

    if valid == [] do
      errors = results |> Enum.filter(&Map.has_key?(&1, :error)) |> Enum.map(& &1.error)
      Target.error(target, List.first(errors) || "All runs failed")
    else
      count = length(valid)

      avg_ttft = round(Enum.sum(Enum.map(valid, & &1.ttft_ms)) / count)
      avg_total = round(Enum.sum(Enum.map(valid, & &1.total_ms)) / count)
      avg_tokens = round(Enum.sum(Enum.map(valid, & &1.tokens)) / count)
      avg_tps = Float.round(Enum.sum(Enum.map(valid, & &1.tps)) / count, 2)

      Target.result(target, %{
        ttft_ms: avg_ttft,
        total_ms: avg_total,
        tokens: avg_tokens,
        tps: avg_tps,
        runs: count
      })
    end
  end

  # ── URL & headers ──────────────────────────────────────────────────────

  defp build_url(base_url, path) do
    base = String.trim_trailing(base_url, "/")
    base <> path
  end

  defp headers(api_key) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key}"}
    ]
  end

  # ── SSE parsing ────────────────────────────────────────────────────────

  defp split_events(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n", parts: :infinity)
    {events, rest} = Enum.split(parts, -1)
    {events, List.first(rest) || ""}
  end

  defp data_line?("data:" <> _), do: true
  defp data_line?("data: " <> _), do: true
  defp data_line?(":" <> _), do: false
  defp data_line?(_), do: false

  defp extract_data("data:" <> rest), do: String.trim_leading(rest, " ")
  defp extract_data("data: " <> rest), do: rest
  defp extract_data(line), do: line

  defp format_error(%{reason: reason}), do: to_string(reason)
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
