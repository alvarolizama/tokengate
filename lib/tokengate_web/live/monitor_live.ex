defmodule TokengateWeb.MonitorLive do
  @moduledoc """
  Real-time model activity monitor — live bars per active model with
  stacked provider/credential segments and in-flight counts on the right.

  Data sources:
    * `Tokengate.Metrics.Collector.snapshot/0` — accumulated request counts
      per model_alias and provider since process start.
    * `Tokengate.Logs.Inflight.list/0` — currently in-flight requests with
      model_requested, provider_name, credential_name.
    * `Tokengate.Logs.Inflight.count_by_model/1` — in-flight count per model.

  Real-time updates via PubSub:
    * `metrics:updated` → re-fetch snapshot + re-render bars.
    * `logs:inflight`    → re-fetch in-flight state + re-render.

  Admin-only (same guard as StatsLive).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Logs.Inflight
  alias Tokengate.Metrics.Collector
  alias Tokengate.Providers

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "metrics:updated")
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Inflight.topic())
      send(self(), :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "Monitor · Tokengate")
      |> assign(:model_rows, [])
      |> assign(:total_inflight, 0)
      |> assign(:total_requests, 0)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, refresh_data(socket)}
  end

  def handle_info({:metrics_updated, _lite}, socket) do
    Process.send_after(self(), :refresh, 200)
    {:noreply, socket}
  end

  def handle_info({:inflight_started, _entry}, socket) do
    Process.send_after(self(), :refresh, 200)
    {:noreply, socket}
  end

  def handle_info({:inflight_done, _id}, socket) do
    Process.send_after(self(), :refresh, 200)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_data(socket) do
    snapshot = Collector.snapshot()
    inflight_entries = Inflight.list()

    # Resolve model alias ids → names
    aliases = Providers.list_model_aliases()
    alias_names = Map.new(aliases, &{&1.id, &1.name})

    # Resolve provider ids → names
    _providers = Providers.list_providers()

    # Build per-model rows from Collector.by_alias
    by_alias = snapshot.by_alias

    inflight_by_model =
      inflight_entries
      |> Enum.reject(&is_nil(&1.model_requested))
      |> Enum.group_by(& &1.model_requested)

    model_rows =
      by_alias
      |> Enum.map(fn {alias_id, count} ->
        model_name = Map.get(alias_names, alias_id, "—")

        # In-flight for this model (match by name)
        model_inflight = Map.get(inflight_by_model, model_name, [])

        # Provider breakdown from in-flight entries
        provider_segments =
          model_inflight
          |> Enum.group_by(fn e ->
            {e.provider_name || "—", e.credential_name || "—"}
          end)
          |> Enum.map(fn {{provider_name, credential_name}, entries} ->
            %{
              provider_name: provider_name,
              credential_name: credential_name,
              count: length(entries)
            }
          end)
          |> Enum.sort_by(& &1.count, :desc)

        inflight_count = length(model_inflight)

        %{
          model_name: model_name,
          requests: count,
          inflight: inflight_count,
          providers: provider_segments
        }
      end)
      |> Enum.sort_by(& &1.requests, :desc)

    total_inflight = length(inflight_entries)

    socket
    |> assign(:model_rows, model_rows)
    |> assign(:total_inflight, total_inflight)
    |> assign(:total_requests, snapshot.requests_total)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @provider_colors ~w(
    bg-blue-500
    bg-emerald-500
    bg-amber-500
    bg-rose-500
    bg-violet-500
    bg-cyan-500
    bg-orange-500
    bg-pink-500
    bg-teal-500
    bg-indigo-500
    bg-lime-500
    bg-fuchsia-500
    bg-sky-500
    bg-red-500
    bg-purple-500
    bg-green-500
  )

  def provider_color(index) do
    Enum.at(@provider_colors, rem(index, length(@provider_colors)))
  end

  def model_max(rows) do
    rows |> Enum.map(& &1.requests) |> Enum.max(fn -> 0 end)
  end

  def bar_width(requests, max) when max > 0 do
    Float.round(requests / max * 100, 1)
  end

  def bar_width(_requests, _max), do: 0.0

  def inflight_badge_class(0), do: "badge-ghost"
  def inflight_badge_class(n) when n > 0, do: "badge-primary"

  def inflight_label(0), do: "0"
  def inflight_label(n), do: to_string(n)

  defp with_thousands_separator(n) when is_integer(n) do
    n
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3, 3, [])
    |> Enum.join(",")
    |> reverse_string()
  end

  defp reverse_string(s), do: s |> String.reverse()

  def format_number(n) when is_integer(n), do: with_thousands_separator(n)
  def format_number(n) when is_float(n), do: Float.to_string(n)
  def format_number(_), do: "0"
end
