defmodule TokengateWeb.BenchmarksLive do
  @moduledoc """
  Provider benchmarks — pick a model alias and compare every provider
  serving it on TTFT, TPS, latency and token count using the same prompt.

  Targets are built from the existing `model_providers` data — no provider
  `/models` calls. Each credential is measured individually; the UI averages
  credentials that share a provider and presents them as one provider with
  an expandable per-credential breakdown. Admin-only.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Benchmarks.{Runner, Target}
  alias Tokengate.Providers

  @default_prompt "Dame la receta de la cochinita"
  @default_max_tokens 262_144
  @default_runs 3

  @impl true
  def mount(_params, _session, socket) do
    model_aliases =
      Providers.list_model_aliases()
      |> Enum.filter(&(&1.model_type == "llm"))
      |> Enum.sort_by(& &1.name)

    socket =
      socket
      |> assign(:page_title, "Providers Benchmarks · Tokengate")
      |> assign(:model_aliases, model_aliases)
      |> assign(:selected_alias, nil)
      |> assign(:targets, [])
      |> assign(:prompt, @default_prompt)
      |> assign(:max_tokens, @default_max_tokens)
      |> assign(:runs, @default_runs)
      |> assign(:running, false)

    {:ok, socket}
  end

  # ── Model alias selection ─────────────────────────────────────────────

  @impl true
  def handle_event("select_alias", %{"alias_id" => alias_id}, socket) do
    selected = Enum.find(socket.assigns.model_aliases, &(&1.id == alias_id))
    targets = if selected, do: build_targets(alias_id), else: []

    {:noreply,
     socket
     |> assign(:selected_alias, selected)
     |> assign(:targets, targets)}
  end

  # ── Prompt + settings ─────────────────────────────────────────────────

  def handle_event("update_prompt", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :prompt, prompt)}
  end

  def handle_event("update_settings", %{"settings" => params}, socket) do
    max_tokens = parse_int(params["max_tokens"], @default_max_tokens, 1, 1_048_576)
    runs = parse_int(params["runs"], 1, 1, 10)

    {:noreply, socket |> assign(:max_tokens, max_tokens) |> assign(:runs, runs)}
  end

  # ── Run benchmarks ────────────────────────────────────────────────────

  def handle_event("run_benchmarks", _params, socket) do
    cond do
      socket.assigns.running ->
        {:noreply, socket}

      socket.assigns.targets == [] ->
        {:noreply, put_flash(socket, :error, "Selecciona un modelo con proveedores.")}

      String.trim(socket.assigns.prompt) == "" ->
        {:noreply, put_flash(socket, :error, "Escribe un prompt.")}

      true ->
        marked = Enum.map(socket.assigns.targets, &Target.running/1)

        socket =
          socket
          |> assign(:targets, marked)
          |> assign(:running, true)

        send(self(), {:run_benchmarks, marked, socket.assigns.prompt})

        {:noreply, socket}
    end
  end

  def handle_event("clear_results", _params, socket) do
    targets = Enum.map(socket.assigns.targets, &%{&1 | result: nil, error: nil, running?: false})
    {:noreply, assign(socket, :targets, targets)}
  end

  # ── Async info handlers ───────────────────────────────────────────────

  @impl true
  def handle_info({:run_benchmarks, targets, prompt}, socket) do
    opts = [max_tokens: socket.assigns.max_tokens, runs: socket.assigns.runs]

    results = Runner.run(targets, prompt, opts)

    updated_targets =
      targets
      |> Enum.zip(results)
      |> Enum.map(fn {original, result} ->
        %{original | result: result.result, error: result.error, running?: false}
      end)

    {:noreply,
     socket
     |> assign(:targets, updated_targets)
     |> assign(:running, false)}
  end

  # ── Target building ───────────────────────────────────────────────────

  # One target per model_provider row (credential × provider_model). Rows
  # can repeat the same credential across scope buckets (global / team /
  # member exclusive) — identical endpoint + key + model, so dedupe.
  defp build_targets(alias_id) do
    alias_id
    |> Providers.list_model_providers()
    |> Enum.uniq_by(&{&1.credential_id, &1.provider_model})
    |> Enum.map(&build_target/1)
  end

  defp build_target(mp) do
    provider = mp.credential.provider

    Target.new(%{
      base_url: provider.base_url,
      api_key: mp.credential.api_key_encrypted,
      model: mp.provider_model,
      label: "#{provider.name} · #{mp.provider_model}",
      provider_name: provider.name,
      credential_name: mp.credential.name,
      credential_id: mp.credential_id,
      priority: mp.priority
    })
  end

  # ── Grouping for template ─────────────────────────────────────────────
  # Credentials are measured individually; the comparison layer averages
  # them per provider. Groups with results sort by avg TPS desc, failures
  # (no successful credential) go last alphabetically.

  def group_results(targets) do
    groups =
      targets
      |> Enum.group_by(& &1.provider_name)
      |> Enum.map(fn {provider, rows} -> summarize_group(provider, rows) end)

    successes =
      groups
      |> Enum.filter(&(&1.success_count > 0))
      |> Enum.sort_by(&(-&1.avg_tps))

    failures =
      groups
      |> Enum.reject(&(&1.success_count > 0))
      |> Enum.sort_by(& &1.provider)

    successes ++ failures
  end

  defp summarize_group(provider, rows) do
    successes = Enum.filter(rows, &Target.success?/1)
    n = length(successes)

    avg = fn key ->
      if n == 0 do
        nil
      else
        successes
        |> Enum.map(&Map.fetch!(&1.result, key))
        |> Enum.sum()
        |> Kernel./(n)
      end
    end

    %{
      provider: provider,
      rows: Enum.sort_by(rows, &(&1.priority || 9_999_999)),
      key_count: length(rows),
      success_count: n,
      error_count: length(rows) - n,
      avg_tps: round2(avg.(:tps)),
      avg_ttft: avg_int(avg.(:ttft_ms)),
      avg_total: avg_int(avg.(:total_ms)),
      avg_tokens: avg_int(avg.(:tokens))
    }
  end

  defp round2(nil), do: nil
  defp round2(value), do: Float.round(value, 2)

  defp avg_int(nil), do: nil
  defp avg_int(value), do: round(value)

  def successful_groups(groups), do: Enum.filter(groups, &(&1.success_count > 0))

  def winner_group(groups) do
    groups
    |> successful_groups()
    |> Enum.max_by(& &1.avg_tps, fn -> nil end)
  end

  def best_ttft_group(groups) do
    groups
    |> successful_groups()
    |> Enum.min_by(& &1.avg_ttft, fn -> nil end)
  end

  def best_latency_group(groups) do
    groups
    |> successful_groups()
    |> Enum.min_by(& &1.avg_total, fn -> nil end)
  end

  # ── Helpers for template ──────────────────────────────────────────────

  def has_results?(targets), do: Enum.any?(targets, &Target.done?/1)

  def provider_names(targets) do
    targets
    |> Enum.map(& &1.provider_name)
    |> Enum.uniq()
  end

  def selected_alias?(%{id: id}, %{id: id}), do: true
  def selected_alias?(_, _), do: false

  def max_metric(groups, key) do
    groups
    |> Enum.map(&Map.fetch!(&1, key))
    |> Enum.max(fn -> 0 end)
  end

  def bar_width(value, max_value) when max_value > 0 do
    Float.round(value / max_value * 100, 1)
  end

  def bar_width(_, _), do: 0.0

  def fmt_ms(ms) when is_number(ms), do: "#{round(ms)}ms"
  def fmt_ms(_), do: "—"

  def fmt_tps(tps) when is_number(tps), do: "#{Float.round(tps, 1)} t/s"
  def fmt_tps(_), do: "—"

  def fmt_tokens(n) when is_number(n), do: "#{n}"
  def fmt_tokens(_), do: "—"

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
end
