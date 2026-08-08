defmodule TokengateWeb.MonitorLive do
  @moduledoc """
  Real-time model activity monitor — trading-terminal style.

  Each model alias is a "ticket" in a watchlist with a 60-minute
  sparkline, requests-per-minute, error rate, cost, and in-flight count.

  Data sources:
    * `Tokengate.Metrics.Window.snapshot/0` — per-minute rolling
      counts (last 60 min) per model_alias_id, backfilled from Postgres.
    * `Tokengate.Metrics.Collector.snapshot/0` — total counters since
      process start (for the "índices" strip and volume numbers).
    * `Tokengate.Logs.Inflight.list/0` — currently in-flight requests.
    * `Tokengate.Metrics.Rollup.breakdown_by_credential/2` — per-credential
      drill-down for the expanded model (last hour from Postgres).

  Real-time updates via PubSub:
    * `metrics:updated` → refresh sparklines + counters.
    * `logs:inflight`    → refresh in-flight badges.
    * `metrics:window`   → window rotated, refresh sparklines.

  Admin-only (same guard as StatsLive).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Logs.Inflight
  alias Tokengate.Metrics.{Collector, Rollup, Window}
  alias Tokengate.Providers

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "metrics:updated")
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Inflight.topic())
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Window.topic())
      send(self(), :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "Monitor · Tokengate")
      |> assign(:tickets, [])
      |> assign(:indices, %{})
      |> assign(:expanded_model, nil)
      |> assign(:credential_rows, [])
      |> assign(:total_inflight, 0)
      |> assign(:active_tab, "model")
      |> assign(:credential_tickets, [])
      |> assign(:expanded_credential, nil)
      |> assign(:credential_model_rows, [])

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

  def handle_info(:window_rotated, socket) do
    Process.send_after(self(), :refresh, 200)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-expand", %{"model-id" => model_id}, socket) do
    new_expanded =
      if socket.assigns[:expanded_model] == model_id, do: nil, else: model_id

    socket =
      socket
      |> assign(:expanded_model, new_expanded)
      |> refresh_credential_rows(new_expanded)

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch-tab", %{"tab" => tab}, socket) do
    socket = assign(socket, :active_tab, tab)
    {:noreply, refresh_data(socket)}
  end

  @impl true
  def handle_event("toggle-expand-credential", %{"credential-name" => cred_name}, socket) do
    new_expanded =
      if socket.assigns[:expanded_credential] == cred_name, do: nil, else: cred_name

    socket =
      socket
      |> assign(:expanded_credential, new_expanded)
      |> refresh_credential_model_rows(new_expanded)

    {:noreply, socket}
  end

  defp refresh_credential_rows(socket, nil), do: assign(socket, :credential_rows, [])

  defp refresh_credential_rows(socket, model_id),
    do:
      assign(
        socket,
        :credential_rows,
        Rollup.breakdown_by_credential(model_id, from: one_hour_ago())
      )

  defp refresh_credential_model_rows(socket, nil), do: assign(socket, :credential_model_rows, [])

  defp refresh_credential_model_rows(socket, cred_name),
    do:
      assign(
        socket,
        :credential_model_rows,
        Rollup.breakdown_by_model_for_credential(cred_name, from: one_hour_ago())
      )

  defp refresh_data(socket) do
    snapshot = Collector.snapshot()
    window = Window.snapshot()
    inflight_entries = Inflight.list()

    # Resolve model alias ids → names
    aliases = Providers.list_model_aliases()

    alias_names =
      aliases
      |> Map.new(&{&1.id, &1.name})

    inflight_by_model =
      inflight_entries
      |> Enum.reject(&is_nil(&1.model_requested))
      |> Enum.group_by(& &1.model_requested)

    # Build tickets: merge Collector counts + Window sparklines + Inflight
    tickets =
      snapshot.by_alias
      |> Enum.map(fn {alias_id, total_count} ->
        model_name = Map.get(alias_names, alias_id, "—")
        sparkline = Map.get(window, alias_id, List.duplicate(0, 60))
        model_inflight = Map.get(inflight_by_model, model_name, [])

        provider_segments =
          model_inflight
          |> Enum.group_by(fn e -> {e.provider_name || "—", e.credential_name || "—"} end)
          |> Enum.map(fn {{provider_name, credential_name}, entries} ->
            %{
              provider_name: provider_name,
              credential_name: credential_name,
              count: length(entries)
            }
          end)
          |> Enum.sort_by(& &1.count, :desc)

        %{
          alias_id: alias_id,
          model_name: model_name,
          total_requests: total_count,
          sparkline: sparkline,
          inflight: length(model_inflight),
          providers: provider_segments
        }
      end)
      |> Enum.sort_by(& &1.total_requests, :desc)

    # Indices strip
    total_inflight = length(inflight_entries)

    # Last-minute RPM: sum of last bucket across all models
    current_rpm =
      window
      |> Enum.map(fn {_id, counts} -> List.last(counts, 0) end)
      |> Enum.sum()

    indices = %{
      rps: Float.round(current_rpm / 60.0, 1),
      inflight: total_inflight,
      error_rate: snapshot.error_rate,
      total_requests: snapshot.requests_total,
      cost_usd: snapshot.cost_usd
    }

    # Refresh credential rows if a model is expanded
    socket =
      if expanded = socket.assigns[:expanded_model] do
        assign(
          socket,
          :credential_rows,
          Rollup.breakdown_by_credential(expanded, from: one_hour_ago())
        )
      else
        socket
      end

    # Build credential tickets for the "Por API key" tab
    cred_window = Window.snapshot_by_credential()

    inflight_by_cred =
      inflight_entries
      |> Enum.reject(&is_nil(&1.credential_name))
      |> Enum.group_by(& &1.credential_name)

    # Resolve provider names for credentials from inflight
    cred_provider_names =
      inflight_entries
      |> Enum.reject(fn e -> is_nil(e.credential_name) or is_nil(e.provider_name) end)
      |> Enum.map(fn e -> {e.credential_name, e.provider_name} end)
      |> Enum.uniq()
      |> Map.new()

    credential_tickets =
      cred_window
      |> Enum.map(fn {cred_name, counts} ->
        cred_inflight = Map.get(inflight_by_cred, cred_name, [])

        %{
          credential_name: cred_name,
          provider_name: Map.get(cred_provider_names, cred_name, "—"),
          sparkline: counts,
          total_requests: Enum.sum(counts),
          inflight: length(cred_inflight)
        }
      end)
      |> Enum.sort_by(& &1.total_requests, :desc)

    # Refresh credential model rows if a credential is expanded
    socket =
      if expanded_cred = socket.assigns[:expanded_credential] do
        assign(
          socket,
          :credential_model_rows,
          Rollup.breakdown_by_model_for_credential(expanded_cred, from: one_hour_ago())
        )
      else
        socket
      end

    socket
    |> assign(:tickets, tickets)
    |> assign(:indices, indices)
    |> assign(:total_inflight, total_inflight)
    |> assign(:credential_tickets, credential_tickets)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp one_hour_ago do
    DateTime.utc_now()
    |> DateTime.add(-3600, :second)
    |> DateTime.truncate(:second)
  end

  # Sparkline SVG points: takes [0, 3, 5, 2, 0, ...] → "0,150 10,120 ..."
  # Width = 120, Height = 30. Each bucket gets width/60 px.
  def sparkline_points(counts) do
    max_val = Enum.max(counts, fn -> 1 end)

    width = 120
    height = 30
    step = width / 60

    counts
    |> Enum.with_index()
    |> Enum.map(fn {count, i} ->
      x = Float.round(i * step, 2)
      # Invert Y: 0 = bottom (height), max = top (0)
      y =
        if max_val > 0 do
          Float.round(height - count / max_val * height, 2)
        else
          height
        end

      "#{x},#{y}"
    end)
    |> Enum.join(" ")
  end

  # Sparkline area path for fill under the line
  def sparkline_area_path(counts) do
    points = sparkline_points(counts)

    # Build a path: start at bottom-left, trace the line, close to bottom-right
    "M0,30 L#{points} L120,30 Z"
  end

  def health_class(error_rate) when error_rate >= 0.05, do: "text-error"
  def health_class(error_rate) when error_rate >= 0.01, do: "text-warning"
  def health_class(_), do: "text-success"

  def health_dot_class(error_rate) when error_rate >= 0.05, do: "bg-error"
  def health_dot_class(error_rate) when error_rate >= 0.01, do: "bg-warning"
  def health_dot_class(_), do: "bg-success"

  def inflight_badge_class(0), do: "badge-ghost"
  def inflight_badge_class(n) when n > 0, do: "badge-primary"

  def inflight_label(0), do: "0"
  def inflight_label(n), do: to_string(n)

  def credential_status_dot(nil), do: "bg-base-content/30"
  def credential_status_dot("active"), do: "bg-success"
  def credential_status_dot("disabled"), do: "bg-base-content/30"
  def credential_status_dot("error"), do: "bg-error"
  def credential_status_dot(_), do: "bg-base-content/30"

  def credential_status_label(nil), do: "—"
  def credential_status_label(s), do: s

  # Delta: current minute count vs avg of previous 10 minutes
  def rpm_delta(counts) do
    current = List.last(counts, 0)
    prev_10 = counts |> Enum.slice(-11, 10) |> Enum.filter(&(&1 > 0))

    if prev_10 == [] do
      cond do
        current > 0 -> "+inf"
        true -> "0%"
      end
    else
      avg = Enum.sum(prev_10) / length(prev_10)

      if avg == 0 do
        if current > 0, do: "+inf", else: "0%"
      else
        pct = (current - avg) / avg * 100

        cond do
          pct > 0 -> "+#{Float.round(pct, 0)}%"
          pct < 0 -> "#{Float.round(pct, 0)}%"
          true -> "0%"
        end
      end
    end
  end

  def rpm_delta_class(delta_str) do
    cond do
      String.starts_with?(delta_str, "+") -> "text-success"
      String.starts_with?(delta_str, "-") -> "text-error"
      true -> "text-base-content/40"
    end
  end

  # Current minute RPM (last bucket of the sparkline)
  def current_rpm(counts), do: List.last(counts, 0)

  # Last-hour volume (sum of sparkline)
  def hour_volume(counts), do: Enum.sum(counts)

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
  def format_number(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  def format_number(_), do: "0"

  def format_cost(%Decimal{} = d) do
    d
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  end

  def format_cost(_), do: "$0.00"

  # ── Function Components ──────────────────────────────────────────────────

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: "text-base-content/60"

  def index_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-3 sm:p-4">
        <div class="flex items-center gap-2 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
          <.icon name={@icon} class={["w-3.5 h-3.5", @color]} />
          {@label}
        </div>
        <p class={["text-xl sm:text-2xl font-bold tabular-nums mt-1", @color]}>
          {@value}
        </p>
      </div>
    </div>
    """
  end

  attr :rows, :list, default: []

  def credential_drilldown(assigns) do
    ~H"""
    <div class="ml-6 md:ml-10 mt-1 mb-2 rounded-lg border border-base-200 bg-base-100/50 overflow-hidden">
      <%!-- Sub-header --%>
      <div class="hidden md:grid grid-cols-[1fr_1fr_1fr_64px_72px_72px_72px_48px] gap-2 px-3 py-1.5 bg-base-200/30 text-[9px] font-semibold uppercase tracking-wider text-base-content/40">
        <span>API Key</span>
        <span>Proveedor</span>
        <span>Usuarios</span>
        <span class="text-right">Req</span>
        <span class="text-right">p95</span>
        <span class="text-right">Err</span>
        <span class="text-right">$</span>
        <span class="text-center">Estado</span>
      </div>

      <%= if @rows == [] do %>
        <p class="text-[11px] text-base-content/40 px-3 py-2">
          Sin datos de credenciales para este modelo en la última hora.
        </p>
      <% else %>
        <div
          :for={row <- @rows}
          class="grid grid-cols-[1fr_1fr_auto] md:grid-cols-[1fr_1fr_1fr_64px_72px_72px_72px_48px] gap-2 px-3 py-1.5 items-center text-[11px] hover:bg-base-200/20 transition-colors border-b border-base-200/30 last:border-b-0"
        >
          <%!-- Credential name --%>
          <span class="font-medium text-base-content/70 truncate">
            {row.credential_name}
          </span>

          <%!-- Provider name --%>
          <span class="text-base-content/50 truncate hidden md:block">
            {row.provider_name}
          </span>

          <%!-- Users --%>
          <div class="flex flex-wrap gap-1">
            <span :for={m <- row[:members] || []} class="badge badge-xs badge-ghost">
              {m.name}
            </span>
          </div>

          <%!-- Request count --%>
          <span class="text-right tabular-nums text-base-content/60">
            {format_number(row.request_count)}
          </span>

          <%!-- p95 latency --%>
          <span class="text-right tabular-nums text-base-content/50 hidden md:block">
            {if row.p95_latency_ms, do: "#{row.p95_latency_ms}ms", else: "—"}
          </span>

          <%!-- Error rate --%>
          <span class={[
            "text-right tabular-nums hidden md:block",
            row.error_rate > 0.05 && "text-error",
            row.error_rate > 0 && row.error_rate <= 0.05 && "text-warning",
            row.error_rate == 0 && "text-base-content/40"
          ]}>
            {Float.round(row.error_rate * 100, 1)}%
          </span>

          <%!-- Cost --%>
          <span class="text-right tabular-nums text-base-content/50 hidden md:block">
            {format_cost(row.cost_usd)}
          </span>

          <%!-- Status dot --%>
          <div class="flex items-center justify-center gap-1">
            <span class={["w-2 h-2 rounded-full", credential_status_dot(row.status)]} />
            <span class="text-[9px] text-base-content/40 hidden md:inline">
              {credential_status_label(row.status)}
            </span>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Credential model drilldown (for the "Por API key" tab) ────────────────
  attr :rows, :list, default: []

  def credential_model_drilldown(assigns) do
    ~H"""
    <div class="ml-6 md:ml-10 mt-1 mb-2 rounded-lg border border-base-200 bg-base-100/50 overflow-hidden">
      <%!-- Sub-header --%>
      <div class="hidden md:grid grid-cols-[1fr_1fr_64px_72px_72px_72px] gap-2 px-3 py-1.5 bg-base-200/30 text-[9px] font-semibold uppercase tracking-wider text-base-content/40">
        <span>Modelo</span>
        <span>Usuarios</span>
        <span class="text-right">Req</span>
        <span class="text-right">p95</span>
        <span class="text-right">Err</span>
        <span class="text-right">$</span>
      </div>

      <%= if @rows == [] do %>
        <p class="text-[11px] text-base-content/40 px-3 py-2">
          Sin datos de modelos para esta API key en la última hora.
        </p>
      <% else %>
        <div
          :for={row <- @rows}
          class="grid grid-cols-[1fr_auto] md:grid-cols-[1fr_1fr_64px_72px_72px_72px] gap-2 px-3 py-1.5 items-center text-[11px] hover:bg-base-200/20 transition-colors border-b border-base-200/30 last:border-b-0"
        >
          <%!-- Model name --%>
          <span class="font-medium text-base-content/70 truncate">
            {row.model_name}
          </span>

          <%!-- Users --%>
          <div class="flex flex-wrap gap-1">
            <span :for={m <- row[:members] || []} class="badge badge-xs badge-ghost">
              {m.name}
            </span>
          </div>

          <%!-- Request count --%>
          <span class="text-right tabular-nums text-base-content/60">
            {format_number(row.request_count)}
          </span>

          <%!-- p95 latency --%>
          <span class="text-right tabular-nums text-base-content/50 hidden md:block">
            {if row.p95_latency_ms, do: "#{row.p95_latency_ms}ms", else: "—"}
          </span>

          <%!-- Error rate --%>
          <span class={[
            "text-right tabular-nums hidden md:block",
            row.error_rate > 0.05 && "text-error",
            row.error_rate > 0 && row.error_rate <= 0.05 && "text-warning",
            row.error_rate == 0 && "text-base-content/40"
          ]}>
            {Float.round(row.error_rate * 100, 1)}%
          </span>

          <%!-- Cost --%>
          <span class="text-right tabular-nums text-base-content/50 hidden md:block">
            {format_cost(row.cost_usd)}
          </span>
        </div>
      <% end %>
    </div>
    """
  end
end
