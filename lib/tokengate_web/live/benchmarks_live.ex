defmodule TokengateWeb.BenchmarksLive do
  @moduledoc """
  Provider benchmarks — compare LLM providers head-to-head on
  TTFT, TPS, latency and token count using the same prompt.

  Targets are built from existing TokenGate providers + credentials.
  Cascading selects: provider → credential (filtered) → model (fetched
  from the provider's /models endpoint). Admin-only.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Benchmarks.{Runner, Target}
  alias Tokengate.Proxy.OpenAIAdapter
  alias Tokengate.Providers
  alias Tokengate.Repo

  @default_prompt "Dame la receta de la cochinita"
  @default_max_tokens 262_144
  @default_runs 3

  @impl true
  def mount(_params, _session, socket) do
    providers =
      from(p in Providers.Provider,
        where: p.status == "active",
        order_by: p.name
      )
      |> Repo.all()

    socket =
      socket
      |> assign(:page_title, "Benchmarks · Tokengate")
      |> assign(:targets, [])
      |> assign(:prompt, @default_prompt)
      |> assign(:max_tokens, @default_max_tokens)
      |> assign(:runs, @default_runs)
      |> assign(:running, false)
      |> assign(:results, [])
      |> assign(:providers, providers)
      |> assign(:selected_provider_id, nil)
      |> assign(:available_credentials, [])
      |> assign(:selected_credential_id, nil)
      |> assign(:available_models, [])
      |> assign(:loading_models, false)
      |> assign(:selected_model, nil)

    {:ok, socket}
  end

  # ── Cascading select events ───────────────────────────────────────────

  @impl true
  def handle_event("select_provider", %{"target" => %{"provider_id" => provider_id}}, socket) do
    credentials =
      if provider_id != "" do
        from(c in Providers.Credential,
          where: c.provider_id == ^provider_id and c.status == "active",
          order_by: [asc: c.name]
        )
        |> Repo.all()
      else
        []
      end

    {:noreply,
     socket
     |> assign(:selected_provider_id, if(provider_id == "", do: nil, else: provider_id))
     |> assign(:available_credentials, credentials)
     |> assign(:selected_credential_id, nil)
     |> assign(:available_models, [])
     |> assign(:selected_model, nil)
     |> assign(:loading_models, false)}
  end

  def handle_event(
        "select_credential",
        %{"target" => %{"credential_id" => credential_id}},
        socket
      ) do
    if credential_id == "" do
      {:noreply,
       socket
       |> assign(:selected_credential_id, nil)
       |> assign(:available_models, [])
       |> assign(:selected_model, nil)}
    else
      provider_id = socket.assigns.selected_provider_id

      if provider_id do
        send(self(), {:fetch_models, provider_id, credential_id})
      end

      {:noreply,
       socket
       |> assign(:selected_credential_id, credential_id)
       |> assign(:available_models, [])
       |> assign(:selected_model, nil)
       |> assign(:loading_models, true)}
    end
  end

  def handle_event("select_model", %{"target" => %{"model" => model}}, socket) do
    {:noreply, assign(socket, :selected_model, if(model == "", do: nil, else: model))}
  end

  # ── Add / remove targets ──────────────────────────────────────────────

  def handle_event("add_target", params, socket) do
    # Params arrive flat from phx-value-* on the button, or nested under
    # "target" from a form submit. Normalize to flat.
    target = Map.get(params, "target", params)
    provider_id = target["provider_id"] || ""
    credential_id = target["credential_id"] || ""
    model = String.trim(target["model"] || "")

    cond do
      provider_id == "" ->
        {:noreply, put_flash(socket, :error, "Selecciona un proveedor.")}

      credential_id == "" ->
        {:noreply, put_flash(socket, :error, "Selecciona una credencial.")}

      model == "" ->
        {:noreply, put_flash(socket, :error, "Selecciona un modelo.")}

      true ->
        case build_target(provider_id, credential_id, model) do
          {:ok, target} ->
            {:noreply,
             socket
             |> assign(:targets, socket.assigns.targets ++ [target])
             |> assign(:selected_model, nil)
             |> assign(:available_models, [])}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
    end
  end

  def handle_event("remove_target", %{"id" => id}, socket) do
    targets = Enum.reject(socket.assigns.targets, &(&1.id == id))
    {:noreply, assign(socket, :targets, targets)}
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
          socket
          |> assign(:targets, marked)
          |> assign(:running, true)
          |> assign(:results, [])

        send(self(), {:run_benchmarks, targets, prompt})

        {:noreply, socket}
    end
  end

  def handle_event("clear_results", _params, socket) do
    targets = Enum.map(socket.assigns.targets, &%{&1 | result: nil, error: nil, running?: false})

    {:noreply, socket |> assign(:targets, targets) |> assign(:results, [])}
  end

  # ── Async info handlers ───────────────────────────────────────────────

  @impl true
  def handle_info({:fetch_models, provider_id, credential_id}, socket) do
    provider = Providers.get_provider(provider_id)
    credential = Providers.get_credential(credential_id)

    models =
      if provider && credential do
        case OpenAIAdapter.list_models(provider, credential) do
          {:ok, models} -> models
          {:error, _} -> []
        end
      else
        []
      end

    {:noreply,
     socket
     |> assign(:available_models, models)
     |> assign(:loading_models, false)}
  end

  def handle_info({:run_benchmarks, targets, prompt}, socket) do
    opts = [max_tokens: socket.assigns.max_tokens, runs: socket.assigns.runs]

    results = Runner.run(targets, prompt, opts)

    updated_targets =
      targets
      |> Enum.zip(results)
      |> Enum.map(fn {original, result} ->
        %{original | result: result.result, error: result.error, running?: false}
      end)

    sorted = sort_by_metric(updated_targets, :tps, :desc)

    socket =
      socket
      |> assign(:targets, updated_targets)
      |> assign(:results, sorted)
      |> assign(:running, false)

    {:noreply, socket}
  end

  # ── Target building ───────────────────────────────────────────────────

  defp build_target(provider_id, credential_id, model) do
    provider = Providers.get_provider(provider_id)
    credential = Providers.get_credential(credential_id)

    cond do
      is_nil(provider) ->
        {:error, "Proveedor no encontrado."}

      is_nil(credential) ->
        {:error, "Credencial no encontrada."}

      credential.provider_id != provider.id ->
        {:error, "La credencial no pertenece a este proveedor."}

      true ->
        target =
          Target.new(%{
            base_url: provider.base_url,
            api_key: credential.api_key_encrypted,
            model: model,
            label: "#{provider.name} · #{model}"
          })

        {:ok, target}
    end
  end

  # ── Helpers for template ──────────────────────────────────────────────

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
