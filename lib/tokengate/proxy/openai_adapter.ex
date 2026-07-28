defmodule Tokengate.Proxy.OpenAIAdapter do
  @moduledoc """
  OpenAI-compatible provider adapter.

  Talks to any endpoint exposing the OpenAI Chat Completions surface:
  `POST /chat/completions` and `GET /models`. The provider's `base_url`
  must include the full API base path (e.g. `https://api.openai.com/v1`,
  `https://openrouter.ai/api/v1`) — the adapter only appends the final
  endpoint segment. The adapter is a thin transport layer — the request
  payload is encoded and forwarded **exactly
  as received**. No system prompts are injected, no messages are modified,
  no fields are stripped or added. The only mutation the adapter performs
  is enforcing `stream: true` on the streaming path, because that flag is
  what activates the SSE transport — the caller already sets it, and the
  adapter only ensures it is present so a misconfigured caller still gets a
  stream rather than a buffered body.

  Uses `Tokengate.Finch` for all HTTP. Streaming needs raw chunk control
  (SSE framing), so the adapter calls `Finch.stream_while/5` directly rather
  than going through `Finch.request/3`.
  """

  @behaviour Tokengate.Proxy.ProviderAdapter

  alias Tokengate.Proxy.ProviderAdapter

  @default_receive_timeout 180_000

  ## Public API ###############################################################

  @impl true
  def chat_completion(provider, credential, payload, opts \\ []) do
    url = chat_completions_url(provider)
    api_key = Map.get(credential, :api_key_encrypted) || Map.get(credential, "api_key_encrypted")
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    body = Jason.encode!(payload)

    request =
      Finch.build(:post, url, headers(api_key), body)

    start = System.monotonic_time(:millisecond)

    case Finch.request(request, finch_name(), receive_timeout: receive_timeout) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        latency = System.monotonic_time(:millisecond) - start
        decoded = decode!(resp_body)
        {:ok, decoded, latency}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, ProviderAdapter.classify_status(status), status,
         extract_error_message(resp_body)}

      {:error, error} ->
        {:error, ProviderAdapter.classify_error(error), nil}
    end
  end

  @impl true
  def stream_chat_completion(provider, credential, payload, opts \\ []) do
    url = chat_completions_url(provider)
    api_key = Map.get(credential, :api_key_encrypted) || Map.get(credential, "api_key_encrypted")
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    # Enforce stream: true. The caller is expected to set it (passthrough),
    # but a missing flag would silently produce a buffered body instead of an
    # SSE stream, so we make sure it is present.
    stream_payload = Map.put(payload, "stream", true)
    body = Jason.encode!(stream_payload)

    request =
      Finch.build(:post, url, headers(api_key), body)

    caller = self()

    {:ok, pid} =
      Task.start(fn ->
        acc = %{caller: caller, buffer: "", done: false, status: nil}

        result =
          Finch.stream_while(
            request,
            finch_name(),
            acc,
            fn entry, acc ->
              case entry do
                {:status, status} ->
                  if status in 200..299 do
                    {:cont, %{acc | status: status}}
                  else
                    # Non-2xx: stop immediately and report the classified error
                    # to the caller — dying silently would leave it hanging.
                    {:halt, %{acc | status: status, done: true}}
                  end

                {:headers, _headers} ->
                  {:cont, acc}

                {:data, data} ->
                  case forward_sse(acc, data) do
                    {:cont, acc} -> {:cont, acc}
                    {:halt, acc} -> {:halt, acc}
                  end

                {:trailers, _trailers} ->
                  {:cont, acc}
              end
            end,
            receive_timeout: receive_timeout
          )

        case result do
          {:ok, %{status: status}} when is_integer(status) and status not in 200..299 ->
            send(caller, {:sse_error, {ProviderAdapter.classify_status(status), status}})

          {:ok, acc} ->
            flush_remaining(acc)

          {:error, error, _acc} ->
            send(caller, {:sse_error, ProviderAdapter.classify_error(error)})
        end
      end)

    {:ok, pid}
  end

  @impl true
  def health_check(provider, credential) do
    url = models_url(provider)
    api_key = Map.get(credential, :api_key_encrypted) || Map.get(credential, "api_key_encrypted")
    request = Finch.build(:get, url, headers(api_key))

    case Finch.request(request, finch_name(), receive_timeout: @default_receive_timeout) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status}} ->
        {:error, ProviderAdapter.classify_status(status)}

      {:error, error} ->
        {:error, ProviderAdapter.classify_error(error)}
    end
  end

  @doc """
  Fetches the list of available model IDs from the provider's `/models`
  endpoint. Returns `{:ok, [model_id, ...]}` on success or
  `{:error, reason}` on failure.
  """
  def list_models(provider, credential) do
    url = models_url(provider)
    api_key = Map.get(credential, :api_key_encrypted) || Map.get(credential, "api_key_encrypted")
    request = Finch.build(:get, url, headers(api_key))

    case Finch.request(request, finch_name(), receive_timeout: @default_receive_timeout) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        decoded = decode!(resp_body)
        models = extract_model_ids(decoded)
        {:ok, models}

      {:ok, %Finch.Response{status: status}} ->
        {:error, ProviderAdapter.classify_status(status)}

      {:error, error} ->
        {:error, ProviderAdapter.classify_error(error)}
    end
  end

  defp extract_model_ids(%{"data" => models}) when is_list(models) do
    models
    |> Enum.map(fn m -> Map.get(m, "id") end)
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  defp extract_model_ids(_), do: []

  ## SSE helpers ##############################################################

  # Forwards accumulated SSE data lines to the caller, handling the framing
  # where events are separated by blank lines ("\n\n"). Returns {:cont, acc}
  # to keep streaming or {:halt, acc} when [DONE] is seen.
  defp forward_sse(acc, data) do
    buffer = acc.buffer <> data
    # Split on the SSE event delimiter. Keep any trailing partial event in
    # the buffer for the next chunk.
    {events, rest} = split_events(buffer)

    acc = %{acc | buffer: rest}

    case Enum.reduce_while(events, acc, fn event, acc ->
           case handle_event(event, acc) do
             {:cont, acc} -> {:cont, acc}
             {:halt, acc} -> {:halt, acc}
           end
         end) do
      {:halt, acc} -> {:halt, acc}
      acc -> {:cont, acc}
    end
  end

  # Splits the buffer on "\n\n", returning complete events and the trailing
  # remainder. Handles both "\n\n" and "\r\n\r\n" delimiters.
  defp split_events(buffer) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n", parts: :infinity)
    {events, rest} = Enum.split(parts, -1)
    {events, List.first(rest) || ""}
  end

  # Processes a single SSE event (one or more lines). Data lines start with
  # "data: ". Comment/heartbeat lines start with ":" and are skipped.
  defp handle_event(event, acc) do
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

        cond do
          String.trim(data) == "[DONE]" ->
            send(acc.caller, {:sse_done})
            {:halt, %{acc | done: true}}

          String.trim(data) == "" ->
            {:cont, acc}

          true ->
            send(acc.caller, {:sse_chunk, data})
            {:cont, acc}
        end
    end
  end

  defp data_line?("data:" <> _rest), do: true
  defp data_line?("data: " <> _rest), do: true
  defp data_line?(": " <> _), do: false
  defp data_line?(":" <> _), do: false
  defp data_line?(_), do: false

  defp extract_data("data:" <> rest), do: String.trim_leading(rest, " ")
  defp extract_data("data: " <> rest), do: rest
  defp extract_data(line), do: line

  # Flushes any remaining buffered SSE data when the stream completes
  # normally.
  defp flush_remaining(acc) do
    if acc.done do
      :ok
    else
      case String.trim(acc.buffer) do
        "" ->
          send(acc.caller, {:sse_done})

        data ->
          # Try to forward any trailing event that didn't end with \n\n.
          handle_event(data, acc)
          send(acc.caller, {:sse_done})
      end
    end
  end

  ## URL & header helpers #####################################################

  defp chat_completions_url(provider) do
    base_url(provider) <> "/chat/completions"
  end

  defp models_url(provider) do
    base_url(provider) <> "/models"
  end

  defp base_url(provider) do
    (Map.get(provider, :base_url) || Map.get(provider, "base_url") || "")
    |> String.trim_trailing("/")
  end

  defp headers(api_key) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key}"}
    ]
  end

  defp finch_name, do: Tokengate.Finch

  defp decode!(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  # Extract a human-readable error message from the provider's error body.
  # Providers return different shapes; we try the most common ones.
  defp extract_error_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} when is_binary(msg) -> truncate_msg(msg)
      {:ok, %{"error" => msg}} when is_binary(msg) -> truncate_msg(msg)
      {:ok, %{"message" => msg}} when is_binary(msg) -> truncate_msg(msg)
      {:ok, %{"detail" => msg}} when is_binary(msg) -> truncate_msg(msg)
      _ -> nil
    end
  end

  defp extract_error_message(_), do: nil

  defp truncate_msg(msg) when byte_size(msg) > 500, do: String.slice(msg, 0, 500) <> "…"
  defp truncate_msg(msg), do: msg
end
