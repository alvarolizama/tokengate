defmodule TokengateWeb.BenchmarksLive do
  @moduledoc """
  Provider benchmarks — compare LLM providers head-to-head on
  TTFT, TPS, latency and token count using the same prompt.

  Admin-only (same guard as MonitorLive).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Benchmarks.{Runner, Target}

  @default_prompt "Escribe un poema corto sobre el vacío fértil del que nace todo."

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Benchmarks · Tokengate")
      |> assign(:targets, [])
      |> assign(:prompt, @default_prompt)
      |> assign(:max_tokens, 256)
      |> assign(:runs, 1)
      |> assign(:running, false)
      |> assign(:results, [])
      |> assign(:new_target, empty_new_target())

    {:ok, socket}
  end

  @impl true
  def handle_event("add_target", %{"target" => params}, socket) do
    base_url = String.trim(params["base_url"] || "")
    api_key = String.trim(params["api_key"] || "")
    model = String.trim(params["model"] || "")

    cond do
      base_url == "" or api_key == "" or model == "" ->
        {:noreply, put_flash(socket, :error, "Completa todos los campos.")}

      true ->
        target = Target.new(%{base_url: base_url, api_key: api_key, model: model})

        {:noreply,
         assign(socket, :targets, socket.assigns.targets ++ [target])
         |> assign(:new_target, empty_new_target())}
    end
  end

  def handle_event("remove_target", %{"id" => id}, socket) do
    targets = Enum.reject(socket.assigns.targets, &(&1.id == id))
    {:noreply, assign(socket, :targets, targets)}
  end

  def handle_event("update_prompt", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :prompt, prompt)}
  end

  def handle_event("update_settings", %{"settings" => params}, socket) do
    max_tokens = parse_int(params["max_tokens"], 256, 1, 4096)
    runs = parse_int(params["runs"], 1, 1, 10)
    {:noreply, socket |> assign(:max_tokens, max_tokens) |> assign(:runs, runs)}
  end

  def handle_event("run_benchmarks", _params, socket) do
    targets = socket.assigns.targets
    prompt = socket.assigns.prompt

    cond do
      socket.assigns.running ->
        {:noreply, socket}

      targets == [] ->
        {:noreply, put_flash(socket, :error, "Agrega al menos un proveedor.")}

      String.trim(prompt) == "" ->
        {:noreply, put_flash(socket, :error, "Escribe un prompt.")}

      true ->
        marked = Enum.map(targets, &Target.running/1)

        socket =
          assign(socket, :targets, marked) |> assign(:running, true) |> assign(:results, [])

        send(self(), {:run_benchmarks, targets, prompt})

        {:noreply, socket}
    end
  end

  def handle_event("clear_results", _params, socket) do
    targets = Enum.map(socket.assigns.targets, &%{&1 | result: nil, error: nil, running?: false})
    {:noreply, socket |> assign(:targets, targets) |> assign(:results, [])}
  end

  @impl true
  def handle_info({:run_benchmarks, targets, prompt}, socket) do
    opts = [max_tokens: socket.assigns.max_tokens, runs: socket.assigns.runs]

    results = Runner.run(targets, prompt, opts)

    # Map results back to targets by position (Runner preserves order)
    updated_targets =
      targets
      |> Enum.zip(results)
      |> Enum.map(fn {original, result} ->
        %{original | result: result.result, error: result.error, running?: false}
      end)

    # Sort results by TPS descending for the winner table
    sorted = sort_by_metric(updated_targets, :tps, :desc)

    socket =
      socket
      |> assign(:targets, updated_targets)
      |> assign(:results, sorted)
      |> assign(:running, false)

    {:noreply, socket}
  end

  # ── Helpers for template ──────────────────────────────────────────────

  def empty_new_target, do: %{"base_url" => "", "api_key" => "", "model" => ""}

  def has_results?(targets), do: Enum.any?(targets, &Target.done?/1)

  def winner(targets) do
    targets
    |> Enum.filter(&Target.success?/1)
    |> Enum.max_by(fn t -> t.result.tps end, fn -> nil end)
  end

  def best_ttft(targets) do
    targets
    |> Enum.filter(&Target.success?/1)
    |> Enum.min_by(fn t -> t.result.ttft_ms end, fn -> nil end)
  end

  def best_latency(targets) do
    targets
    |> Enum.filter(&Target.success?/1)
    |> Enum.min_by(fn t -> t.result.total_ms end, fn -> nil end)
  end

  def bar_width(value, max_value) when max_value > 0 do
    Float.round(value / max_value * 100, 1)
  end

  def bar_width(_, _), do: 0.0

  def max_tps(targets) do
    targets
    |> Enum.filter(&Target.success?/1)
    |> Enum.map(& &1.result.tps)
    |> Enum.max(fn -> 0 end)
  end

  def max_ttft(targets) do
    targets
    |> Enum.filter(&Target.success?/1)
    |> Enum.map(& &1.result.ttft_ms)
    |> Enum.max(fn -> 0 end)
  end

  def max_latency(targets) do
    targets
    |> Enum.filter(&Target.success?/1)
    |> Enum.map(& &1.result.total_ms)
    |> Enum.max(fn -> 0 end)
  end

  def max_tokens_count(targets) do
    targets
    |> Enum.filter(&Target.success?/1)
    |> Enum.map(& &1.result.tokens)
    |> Enum.max(fn -> 0 end)
  end

  def fmt_ms(ms) when is_number(ms), do: "#{round(ms)}ms"
  def fmt_ms(_), do: "—"

  def fmt_tps(tps), do: "#{Float.round(tps, 1)} t/s"
  def fmt_tokens(n), do: "#{n}"

  def mask_key(key) when is_binary(key) and byte_size(key) > 8 do
    String.slice(key, 0, 4) <> "…" <> String.slice(key, -4, 4)
  end

  def mask_key(key), do: key

  # ── Private ───────────────────────────────────────────────────────────

  defp parse_int(str, default, min, max) do
    case Integer.parse(str || "") do
      {n, _} when n >= min and n <= max -> n
      {n, _} when n < min -> min
      {n, _} when n > max -> max
      _ -> default
    end
  end

  defp sort_by_metric(targets, metric, direction) do
    valid = Enum.filter(targets, &Target.success?/1)
    invalid = Enum.reject(targets, &Target.success?/1)

    sorted =
      case metric do
        :tps -> Enum.sort_by(valid, & &1.result.tps, direction)
        :ttft -> Enum.sort_by(valid, & &1.result.ttft_ms, direction)
        :latency -> Enum.sort_by(valid, & &1.result.total_ms, direction)
      end

    sorted ++ invalid
  end
end
