defmodule TokengateWeb.ServiceStatsLive do
  @moduledoc """
  Admin-only consolidated stats page for a **service**, aggregating its
  request logs (services carry `service_id`, not `group_member_id`).

  Mirror of `UserStatsLive` for the service subject: aggregated stat cards
  (requests, cost, tokens, top models, status breakdown, last request) and a
  paginated stream of the service's recent logs. Real-time updates via the
  same `logs:new` PubSub as `/logs`.

  Path: `/stats/services/:service_id`

  Admin-only by router; defense-in-depth `require_admin_hook/1` rejects event
  traffic from non-admins (a malicious client could otherwise fire events
  directly over the WebSocket).
  """

  use TokengateWeb, :live_view
  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.DashboardCache
  alias TokengateWeb.KpiHelpers

  @page_size 50
  @summary_refresh_interval_ms 2_000

  # Selector global de periodo: maneja los KPIs, el desglose, los top models
  # y la tabla de keys — una sola ventana por consulta, como la página
  # supervisada. "Este mes" empieza el día 1 en la zona del usuario, por eso
  # el timezone entra a la llave del DashboardCache.
  @periods ~w(24h 7d 30d month)
  @default_period "7d"

  @impl true
  def mount(%{"service_id" => service_id}, _session, socket) do
    service = Accounts.get_service!(service_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
    end

    socket =
      socket
      |> assign(:page_title, gettext("Stats") <> " · #{service.name} · Tokengate")
      |> assign(:service, service)
      # Todas las keys del servicio (activas y revocadas, más recientes
      # primero) — la fuente de las filas de la tabla de API keys.
      |> assign(:service_api_keys, Accounts.list_api_keys_for_service_all(service_id))
      |> assign(:period, @default_period)
      |> assign(:period_form, to_form(%{"period" => @default_period}, as: :period))
      |> assign(:key_filter, "all")
      |> assign(:key_filter_form, to_form(%{"key_id" => "all"}, as: :key_filter))
      |> assign(:timezone, socket.assigns[:timezone] || "Etc/UTC")
      |> assign(:is_admin, socket.assigns[:current_user].global_role == "admin")
      |> assign(:filters, default_filters())
      |> assign(:form, to_form(default_filters(), as: :filter))
      |> assign(:cursor, nil)
      |> assign(:has_more, false)
      |> assign(:page_size, @page_size)
      |> assign(:summary, default_summary())
      |> assign(:key_rows, [])
      |> assign(:summary_refresh_scheduled, false)
      |> require_admin_hook()
      |> load_summary()
      |> load_logs(:reset)

    {:ok, socket}
  end

  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  ## Real-time -------------------------------------------------------------

  @impl true
  def handle_info({:new_log, log}, socket) do
    if log.service_id == socket.assigns.service.id do
      timezone = socket.assigns.timezone
      filters = socket.assigns.filters

      if log_matches_filters?(log, filters, timezone, socket.assigns.key_filter) do
        socket = stream_insert(socket, :logs, log, at: 0)

        # Coalesce summary reloads: at most one service_stats recompute per
        # interval per connected LiveView, regardless of broadcast rate.
        socket =
          if socket.assigns[:summary_refresh_scheduled] do
            socket
          else
            Process.send_after(self(), :refresh_summary, @summary_refresh_interval_ms)
            assign(socket, :summary_refresh_scheduled, true)
          end

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_summary, socket) do
    {:noreply,
     socket
     |> assign(:summary_refresh_scheduled, false)
     |> load_summary()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    filter_params =
      params
      |> Map.get("filter", %{})
      |> then(&Map.merge(default_filters(), &1))

    socket =
      socket
      |> assign(:filters, filter_params)
      |> assign(:form, to_form(filter_params, as: :filter))
      |> assign(:cursor, nil)
      |> load_logs(:reset)

    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply, load_logs(socket, :more)}
    else
      {:noreply, socket}
    end
  end

  # El selector global de periodo re-consulta summary y desglose por key con
  # el MISMO `from` (load_summary), así que la suma de la tabla sigue cuadrando
  # con el KPI en cualquier ventana.
  # El form serializa anidado (to_form as: :period → name="period[period]"):
  # el payload real del browser es %{"period" => %{"period" => p}}.
  def handle_event("set_period", %{"period" => %{"period" => period}}, socket)
      when period in @periods do
    {:noreply,
     socket
     |> assign(:period, period)
     |> assign(:period_form, to_form(%{"period" => period}, as: :period))
     |> load_summary()}
  end

  # Payload manual por el socket con un periodo desconocido: se ignora y la
  # página queda en el periodo vigente.
  def handle_event("set_period", _params, socket), do: {:noreply, socket}

  # Selector de key del reporte: "all" (todas, revocadas incluidas) o el id de
  # una key del servicio. Con una key específica, summary/desglose/top models
  # se scopean por `api_key_id` (Logs.service_stats/2), la tabla muestra sólo
  # esa fila y la lista de logs se refiltra. Ids que no son del servicio se
  # ignoran (payload manual por el socket).
  #
  # Igual que set_period: el form serializa anidado (as: :key_filter →
  # name="key_filter[key_id]").
  def handle_event("set_key", %{"key_filter" => %{"key_id" => key_id}}, socket) do
    known_ids = MapSet.new(socket.assigns.service_api_keys, & &1.id)

    if key_id == "all" or MapSet.member?(known_ids, key_id) do
      {:noreply,
       socket
       |> assign(:key_filter, key_id)
       |> assign(:key_filter_form, to_form(%{"key_id" => key_id}, as: :key_filter))
       |> load_summary()
       |> load_logs(:reset)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_key", _params, socket), do: {:noreply, socket}

  ## Data loading ---------------------------------------------------------

  defp load_summary(socket) do
    service_id = socket.assigns.service.id
    period = socket.assigns.period
    timezone = socket.assigns.timezone

    # The service_stats call is the expensive part of every PubSub refresh
    # here. Wrap it in the shared DashboardCache ETS (5s TTL, keyed per
    # service + period + timezone) so N admins watching this page share one
    # recompute every ~5s instead of each running it on every coalesced
    # refresh.
    #
    # Summary y desglose por key leen el MISMO `from`: dos cómputos con froms
    # independientes mueven el borde de la ventana entre sí y la suma de la
    # tabla se desfaza del KPI por las filas de ese borde.
    from = period_from(period, timezone)

    # El group by de la tabla SIEMPRE es del servicio completo (una query, el
    # trim a una fila es en memoria); el summary sí se scopea por key cuando
    # el selector lo pide — y su llave de cache lleva el scope.
    key_filter = socket.assigns.key_filter

    key_stats =
      DashboardCache.fetch_or_compute({:service_key_stats, service_id, period, timezone}, fn ->
        Logs.service_key_stats(service_id, from: from)
      end)

    key_rows =
      case key_filter do
        "all" ->
          build_key_rows(socket.assigns.service_api_keys, key_stats)

        key_id ->
          build_key_rows(socket.assigns.service_api_keys, key_stats)
          |> Enum.filter(&(&1.stats.api_key_id == key_id))
      end

    summary_opts =
      if key_filter == "all" do
        [from: from]
      else
        [from: from, api_key_id: key_filter]
      end

    socket
    |> assign(
      :summary,
      DashboardCache.fetch_or_compute(
        {:service_stats, service_id, period, timezone, key_filter},
        fn -> Logs.service_stats(service_id, summary_opts) end
      )
    )
    |> assign(:key_rows, key_rows)
  end

  # Universo de la tabla de API keys: TODAS las keys del servicio (preload
  # `:api_keys`, revocadas incluidas) ∪ los ids con tráfico del group by ∪ el
  # grupo NULL. El join de labels y agregados es en memoria por `api_key_id`:
  # el LiveView no agrega queries (§Constraints#3).
  #
  # - key del preload sin tráfico en la ventana → ceros y su badge;
  # - id huérfano (key borrada) → se etiqueta con el `api_key_prefix` del log,
  #   nunca con el uuid desnudo;
  # - grupo NULL → fila "Unattributed", sólo si trae tráfico.
  defp build_key_rows(api_keys, key_stats) do
    stats_by_id = Map.new(key_stats, fn row -> {row.api_key_id, row} end)
    known_ids = MapSet.new(api_keys, & &1.id)

    key_rows =
      Enum.map(api_keys, fn key ->
        %{
          # El id del DOM usa el id de la key (único): el `key_prefix` no tiene
          # unique y dos keys —o una viva y una huérfana— podían colisionar.
          dom_id: "api-key-row-" <> key.id,
          label: key.label || key.key_prefix || key.id,
          status: key.status,
          stats: Map.get(stats_by_id, key.id) || empty_key_stats(key.id)
        }
      end)

    orphan_rows =
      key_stats
      |> Enum.reject(&(is_nil(&1.api_key_id) or MapSet.member?(known_ids, &1.api_key_id)))
      |> Enum.map(fn row ->
        %{
          dom_id: "api-key-row-" <> row.api_key_id,
          label: row.api_key_prefix || "—",
          status: nil,
          stats: row
        }
      end)

    unattributed_rows =
      case Enum.find(key_stats, &is_nil(&1.api_key_id)) do
        nil ->
          []

        row ->
          [
            %{
              dom_id: "api-key-row-unattributed",
              label: gettext("Unattributed"),
              status: nil,
              stats: row
            }
          ]
      end

    key_rows ++ orphan_rows ++ unattributed_rows
  end

  defp empty_key_stats(api_key_id) do
    %{
      api_key_id: api_key_id,
      request_count: 0,
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      last_request_at: nil,
      api_key_prefix: nil
    }
  end

  defp load_logs(socket, mode) do
    service_id = socket.assigns.service.id

    base_filters =
      socket.assigns.filters
      |> Map.put("service_id", service_id)
      |> maybe_key_filter(socket.assigns.key_filter)
      |> drop_empty_filters()

    logs =
      case mode do
        :reset ->
          Logs.list_logs(Map.put(base_filters, "limit", @page_size))

        :more ->
          cursor_filters =
            if socket.assigns.cursor do
              Map.put(base_filters, "before", socket.assigns.cursor)
            else
              base_filters
            end

          Logs.list_logs(Map.put(cursor_filters, "limit", @page_size))
      end

    has_more = length(logs) == @page_size

    socket =
      socket
      |> assign(:has_more, has_more)
      |> case do
        s when mode == :reset ->
          s |> stream(:logs, logs, reset: true)

        s ->
          s |> stream(:logs, logs)
      end

    case logs do
      [] ->
        socket

      _ ->
        oldest = List.last(logs)
        assign(socket, :cursor, oldest.inserted_at)
    end
  end

  # Logs.list_logs/1 doesn't tolerate empty-string values for boolean fields
  # (streaming) — strip them before forwarding.
  defp drop_empty_filters(filters) do
    filters
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  # El selector de key acota también la lista de logs; "all" no entra como
  # filtro (drop_empty_filters lo toleraría, pero es más claro no ponerlo).
  defp maybe_key_filter(filters, "all"), do: filters

  defp maybe_key_filter(filters, key_id) when is_binary(key_id),
    do: Map.put(filters, "api_key_id", key_id)

  defp default_filters do
    %{
      "status_class" => "",
      "streaming" => "",
      "from" => "",
      "to" => "",
      "model_search" => ""
    }
  end

  defp default_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      request_count: 0,
      avg_latency_ms: nil,
      avg_tps: 0.0,
      avg_ttft_ms: nil,
      status_breakdown: %{"2xx" => 0, "4xx" => 0, "5xx" => 0},
      top_models: [],
      last_request_at: nil,
      realtime_5min: %{request_count: 0, error_count: 0, avg_latency_ms: nil, error_rate: 0.0}
    }
  end

  ## Filter helpers -------------------------------------------------------

  defp log_matches_filters?(log, filters, timezone, key_filter) do
    status_class = filters["status_class"]
    streaming = filters["streaming"]
    search = filters["model_search"]

    cond do
      status_class not in [nil, ""] and not status_class_match?(log.status_code, status_class) ->
        false

      streaming not in [nil, ""] and not streaming_match?(log.streaming, streaming) ->
        false

      search not in [nil, ""] and
          not (String.contains?(log.model_requested || "", search) or
                   String.contains?(log.model_responded || "", search)) ->
        false

      # El selector de key acota también el realtime: un log de otra key no
      # entra al stream cuando se está viendo una key específica.
      key_filter not in [nil, "all"] and log.api_key_id != key_filter ->
        false

      true ->
        date_range_match?(log.inserted_at, filters["from"], filters["to"], timezone)
    end
  end

  defp status_class_match?(_, ""), do: true
  defp status_class_match?(status, "2xx"), do: status >= 200 and status < 300
  defp status_class_match?(status, "4xx"), do: status >= 400 and status < 500
  defp status_class_match?(status, "5xx"), do: status >= 500 and status < 600
  defp status_class_match?(_, _), do: true

  defp streaming_match?(_, ""), do: true
  defp streaming_match?(streaming, "true"), do: streaming == true
  defp streaming_match?(streaming, "false"), do: streaming == false
  defp streaming_match?(_, _), do: true

  defp date_range_match?(_dt, "", "", _timezone), do: true

  defp date_range_match?(dt, from, to, timezone) do
    after_from =
      case parse_date_string(from, timezone) do
        nil -> true
        from_dt -> DateTime.compare(dt, from_dt) != :lt
      end

    before_to =
      case parse_date_string(to, timezone, :end_of_day) do
        nil -> true
        to_dt -> DateTime.compare(dt, to_dt) != :gt
      end

    after_from and before_to
  end

  defp parse_date_string(date_str, timezone, mode \\ :start_of_day)

  defp parse_date_string("", _tz, _mode), do: nil
  defp parse_date_string(nil, _tz, _mode), do: nil

  defp parse_date_string(date_str, timezone, mode) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        time =
          case mode do
            :start_of_day -> ~T[00:00:00]
            :end_of_day -> ~T[23:59:59]
          end

        date
        |> DateTime.new!(time, timezone)
        |> DateTime.shift_zone!("Etc/UTC")

      _ ->
        nil
    end
  end

  defp days_ago(n) do
    DateTime.utc_now()
    |> DateTime.add(-n * 24 * 60 * 60, :second)
    |> DateTime.truncate(:second)
  end

  # ... y las ventanas que sirven los helpers:
  defp period_from("24h", _timezone),
    do: DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.truncate(:second)

  defp period_from("7d", _timezone), do: days_ago(7)
  defp period_from("30d", _timezone), do: days_ago(30)

  defp period_from("month", timezone) do
    timezone
    |> DateTime.now!()
    |> DateTime.to_date()
    |> Date.beginning_of_month()
    |> DateTime.new!(~T[00:00:00], timezone)
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp period_label("24h"), do: gettext("Last 24 hours")
  defp period_label("7d"), do: gettext("Last 7 days")
  defp period_label("30d"), do: gettext("Last 30 days")
  defp period_label("month"), do: gettext("This month")

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="space-y-6">
        <%!-- Header --%>
        <header class="flex items-center justify-between gap-6 pb-4">
          <div>
            <div class="flex items-center gap-2 text-xs text-base-content/60">
              <.link navigate={~p"/stats/services"} class="hover:underline">{gettext("Services")}</.link>
              <span>›</span>
              <span>{gettext("Detail")}</span>
            </div>
            <h1 class="text-lg font-semibold leading-8 mt-1">
              {@service.name}
            </h1>
            <p class="text-sm text-base-content/70">
              Presupuesto: {limit_label(@service)}
            </p>
          </div>
          <div class="flex-1"></div>
          <.form
            :if={@service_api_keys != []}
            for={@key_filter_form}
            id="key-filter-form"
            phx-change="set_key"
            class="w-48"
          >
            <.input
              field={@key_filter_form[:key_id]}
              type="select"
              label={gettext("API key")}
              options={[
                {gettext("All API keys"), "all"}
                | Enum.map(@service_api_keys, fn key ->
                    label =
                      (key.label || key.key_prefix) <>
                        if(key.status == "revoked", do: " · " <> gettext("Revoked"), else: "")

                    {label, key.id}
                  end)
              ]}
            />
          </.form>
          <.form for={@period_form} id="period-form" phx-change="set_period" class="w-48">
            <.input
              field={@period_form[:period]}
              type="select"
              label={gettext("Period")}
              options={[
                {period_label("24h"), "24h"},
                {period_label("7d"), "7d"},
                {period_label("30d"), "30d"},
                {period_label("month"), "month"}
              ]}
            />
          </.form>
        </header>

        <%!-- KPI cards (selected period) --%>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
          <.stat_card
            id="kpi-requests"
            label={gettext("Requests")}
            value={Integer.to_string(@summary.request_count)}
            sub={safe_sub_count(@summary.realtime_5min.request_count, " en 5 min")}
            icon="hero-squares-2x2"
          />
          <.stat_card
            label={gettext("Cost")}
            value={fmt_money(@summary.total_cost_usd)}
            sub={safe_sub_count(@summary.request_count, " reqs")}
            icon="hero-currency-dollar"
          />
          <.stat_card
            label={gettext("Input tokens")}
            value={format_number(@summary.total_prompt_tokens)}
            sub={
              "cached " <>
                format_number(@summary.total_cache_read_tokens) <>
                " · hit " <>
                KpiHelpers.format_hit_rate(
                  KpiHelpers.cache_hit_rate(
                    @summary.total_cache_read_tokens,
                    @summary.total_prompt_tokens
                  )
                )
            }
            icon="hero-arrow-down-on-square-stack"
          />
          <.stat_card
            label={gettext("Output tokens")}
            value={format_number(@summary.total_completion_tokens)}
            sub={gettext("avg TPS:") <> " " <> fmt_tps(@summary.avg_tps)}
            icon="hero-arrow-up-on-square-stack"
          />
          <.stat_card
            label={gettext("Errors")}
            value={
              Integer.to_string(@summary.status_breakdown["4xx"] + @summary.status_breakdown["5xx"])
            }
            sub={safe_sub_count(@summary.realtime_5min.error_rate, "% (5 min)")}
            icon="hero-exclamation-triangle"
            tone={error_tone(@summary.status_breakdown)}
          />
          <.stat_card
            label={gettext("Last request")}
            value={last_request_label(@summary.last_request_at, @timezone)}
            sub={"latency prom: " <> fmt_ms(@summary.avg_latency_ms)}
            icon="hero-clock"
          />
        </div>

        <%!-- Service + Status breakdown + Top models --%>
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-3">
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <h3 class="text-sm font-semibold mb-2">{gettext("Service")}</h3>
              <ul class="space-y-1 text-sm">
                <li class="flex items-center justify-between">
                  <span class="text-base-content/60">{gettext("Monthly cap")}</span>
                  <span>{limit_label(@service)}</span>
                </li>
                <li class="flex items-center justify-between">
                  <span class="text-base-content/60">{gettext("Extra concurrency")}</span>
                  <span>{@service.concurrency_limit || 0}</span>
                </li>
                <li class="flex items-center justify-between">
                  <span class="text-base-content/60">{gettext("Extra RPM")}</span>
                  <span>{@service.rpm_limit || 0}</span>
                </li>
              </ul>
            </div>
          </div>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <h3 class="text-sm font-semibold mb-2">{gettext("Status breakdown")}</h3>
              <div class="space-y-2">
                <.status_row
                  class_label="2xx"
                  count={@summary.status_breakdown["2xx"]}
                  tone="success"
                />
                <.status_row
                  class_label="4xx"
                  count={@summary.status_breakdown["4xx"]}
                  tone="warning"
                />
                <.status_row
                  class_label="5xx"
                  count={@summary.status_breakdown["5xx"]}
                  tone="error"
                />
              </div>
            </div>
          </div>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <h3 class="text-sm font-semibold mb-2">{gettext("Top models")}</h3>
              <%= if @summary.top_models == [] do %>
                <p class="text-xs text-base-content/40">
                  {gettext("No requests in this period.")}
                </p>
              <% else %>
                <ol class="space-y-1">
                  <li
                    :for={row <- @summary.top_models}
                    class="flex items-center justify-between text-sm"
                  >
                    <span class="font-mono">{row.model_requested || "—"}</span>
                    <span class="badge badge-sm badge-ghost">
                      {Integer.to_string(row.count)}
                    </span>
                  </li>
                </ol>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- API keys (selected period, full universe: every key ∪ traffic ids ∪ NULL) --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <h3 class="text-sm font-semibold mb-2">{gettext("API keys")}</h3>
            <div class="overflow-x-auto">
              <table class="table table-sm" id="service-api-keys-table">
                <thead>
                  <tr>
                    <th>{gettext("Key")}</th>
                    <th>{gettext("Status")}</th>
                    <th class="text-right">{gettext("Requests")}</th>
                    <th class="text-right">{gettext("Input")}</th>
                    <th class="text-right">{gettext("Output")}</th>
                    <th class="text-right">{gettext("Cost")}</th>
                    <th>{gettext("Last request")}</th>
                  </tr>
                </thead>
                <tbody>
                  <%= if @key_rows == [] do %>
                    <tr id="service-api-keys-empty">
                      <td colspan="7" class="text-center py-6 text-base-content/40">
                        {gettext("This service has no API keys.")}
                      </td>
                    </tr>
                  <% else %>
                    <tr :for={row <- @key_rows} id={row.dom_id}>
                      <td class="font-mono text-sm">{row.label}</td>
                      <td>
                        <%= if row.status do %>
                          <span class={[
                            "badge badge-sm",
                            if(row.status == "active", do: "badge-success", else: "badge-error")
                          ]}>
                            {row.status}
                          </span>
                        <% else %>
                          <span class="text-base-content/40">—</span>
                        <% end %>
                      </td>
                      <td class="text-right text-sm font-mono">
                        {format_number(row.stats.request_count)}
                      </td>
                      <td class="text-right text-sm">
                        {format_number(row.stats.total_prompt_tokens)}
                      </td>
                      <td class="text-right text-sm">
                        {format_number(row.stats.total_completion_tokens)}
                      </td>
                      <td class="text-right text-sm font-mono">
                        {fmt_money(row.stats.total_cost_usd)}
                      </td>
                      <td class="text-sm">
                        {last_request_label(row.stats.last_request_at, @timezone)}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <%!-- Filter form --%>
        <.form
          for={@form}
          id="service-stats-filter-form"
          phx-change="filter"
          class="grid grid-cols-2 md:grid-cols-4 gap-3"
        >
          <.input
            field={@form[:status_class]}
            type="select"
            prompt="Todos"
            options={[{"2xx", "2xx"}, {"4xx", "4xx"}, {"5xx", "5xx"}]}
            label={gettext("Status")}
          />
          <.input
            field={@form[:streaming]}
            type="select"
            prompt="Todos"
            options={[{gettext("Yes"), "true"}, {gettext("No"), "false"}]}
            label={gettext("Streaming")}
          />
          <.input
            field={@form[:model_search]}
            type="text"
            label={gettext("Model")}
          />
          <.input
            field={@form[:from]}
            type="date"
            label="Desde"
          />
          <.input
            field={@form[:to]}
            type="date"
            label="Hasta"
          />
        </.form>

        <%!-- Logs table (stream) --%>
        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Modelo</th>
                <th>Agente</th>
                <th>Streaming</th>
                <th>Estado</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">Costo</th>
                <th class="text-right">Latencia</th>
              </tr>
            </thead>
            <tbody id="service-stats-logs" phx-update="stream">
              <tr id="service-stats-logs-empty" class="hidden only:table-row">
                <td colspan="9" class="text-center py-8 text-base-content/40">
                  {gettext("No requests with the current filters.")}
                </td>
              </tr>
              <tr :for={{id, log} <- @streams.logs} id={id}>
                <td class="whitespace-nowrap text-sm">
                  {TokengateWeb.TimezoneHelper.format_datetime(log.inserted_at, @timezone)}
                </td>
                <td class="text-sm">
                  {model_display(log.model_requested, log.model_responded)}
                </td>
                <td class="text-sm">{log.client_agent || "—"}</td>
                <td>{if log.streaming, do: gettext("Yes"), else: gettext("No")}</td>
                <td>
                  <span class={["badge badge-sm", status_badge(log.status_code)]}>
                    {Integer.to_string(log.status_code)}
                  </span>
                </td>
                <td class="text-right text-sm">{format_number(log.prompt_tokens || 0)}</td>
                <td class="text-right text-sm">{format_number(log.completion_tokens || 0)}</td>
                <td class="text-right text-sm font-mono">${format_cost(log.provider_cost_usd)}</td>
                <td class="text-right text-sm">{format_number(log.latency_ms || 0)} ms</td>
              </tr>
            </tbody>
          </table>
        </div>

        <%= if @has_more do %>
          <div class="flex justify-center">
            <button
              phx-click="load_more"
              class="btn btn-ghost btn-sm"
              id="load-more-service-stats-logs"
            >
              {gettext("Load more")}
            </button>
          </div>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: ""
  attr :icon, :string, default: "hero-chart-bar"
  attr :tone, :string, default: "default"
  attr :id, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4">
        <div class="flex items-center justify-between">
          <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
            {@label}
          </p>
          <.icon name={@icon} class="w-4 h-4 text-base-content/40" />
        </div>
        <p class={["mt-1 text-2xl font-bold", tone_class(@tone)]}>
          {@value}
        </p>
        <p :if={@sub != ""} class="text-xs text-base-content/40 mt-1">{@sub}</p>
      </div>
    </div>
    """
  end

  attr :class_label, :string, required: true
  attr :count, :integer, default: 0
  attr :tone, :string, default: "default"

  defp status_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <span class={["badge badge-sm", row_tone(@tone)]}>{@class_label}</span>
      <span class="text-sm font-mono">{Integer.to_string(@count)}</span>
    </div>
    """
  end

  defp tone_class("error"), do: "text-error"
  defp tone_class("warning"), do: "text-warning"
  defp tone_class("success"), do: "text-success"
  defp tone_class(_), do: "text-base-content"

  defp row_tone("error"), do: "badge-error"
  defp row_tone("warning"), do: "badge-warning"
  defp row_tone("success"), do: "badge-success"
  defp row_tone(_), do: "badge-ghost"

  defp error_tone(%{"5xx" => n}) when n > 0, do: "error"
  defp error_tone(%{"4xx" => n}) when n > 0, do: "warning"
  defp error_tone(_), do: "default"

  ## Format helpers -------------------------------------------------------

  defp format_cost(%Decimal{} = d) do
    d |> Decimal.to_float() |> :erlang.float_to_binary([:compact, {:decimals, 6}])
  end

  defp format_cost(nil), do: "—"

  defp format_number(n) when is_integer(n) do
    digits = Integer.to_string(abs(n))

    grouped =
      digits
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    if n < 0, do: "-" <> grouped, else: grouped
  end

  defp format_number(_), do: "0"

  defp fmt_money(%Decimal{} = d) do
    "$" <> (d |> Decimal.to_float() |> :erlang.float_to_binary([:compact, {:decimals, 4}]))
  end

  defp fmt_money(_), do: "$0"

  defp fmt_tps(nil), do: "—"
  defp fmt_tps(tps) when tps in [+0.0, -0.0, 0.0], do: "—"

  defp fmt_tps(tps) when is_number(tps) do
    tps |> Float.round(1) |> :erlang.float_to_binary([:compact, {:decimals, 1}])
  end

  defp fmt_tps(_), do: "—"

  defp fmt_ms(nil), do: "—"
  defp fmt_ms(ms) when is_number(ms), do: "#{Float.round(ms, 0) |> trunc()} ms"
  defp fmt_ms(_), do: "—"

  defp model_display(req, resp) do
    cond do
      is_binary(resp) and resp != "" and resp != req -> "#{req} → #{resp}"
      true -> req || "—"
    end
  end

  defp status_badge(code) when is_integer(code) and code >= 200 and code < 300,
    do: "badge-success"

  defp status_badge(code) when is_integer(code) and code >= 400 and code < 500,
    do: "badge-warning"

  defp status_badge(code) when is_integer(code) and code >= 500 and code < 600,
    do: "badge-error"

  defp status_badge(_), do: "badge-ghost"

  defp last_request_label(nil, _tz), do: "—"

  defp last_request_label(%DateTime{} = dt, tz),
    do: TokengateWeb.TimezoneHelper.format_datetime(dt, tz)

  defp safe_sub_count(n, suffix) when is_integer(n), do: Integer.to_string(n) <> suffix

  defp safe_sub_count(f, suffix) when is_float(f),
    do: :erlang.float_to_binary(f, [:compact, {:decimals, 1}]) <> suffix

  defp safe_sub_count(_, suffix), do: "0" <> suffix

  # Etiqueta del gasto del servicio: ilimitado, su techo mensual, o sin
  # presupuesto (solo top-ups) — el modelo no tiene suscripciones.
  defp limit_label(%{unlimited_spend: true}), do: "Ilimitado"

  defp limit_label(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: gettext("Cap $%{amount}/month", amount: Decimal.to_string(limit))

  defp limit_label(_), do: gettext("No budget")
end
