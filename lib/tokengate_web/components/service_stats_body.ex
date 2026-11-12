defmodule TokengateWeb.ServiceStatsBody do
  @moduledoc """
  Cuerpo de stats de **un servicio** — una sola fuente de markup, carga y
  helpers para las dos vistas que lo muestran:

    * `TokengateWeb.ServiceStatsLive` — `/stats/services/:service_id` (admin);
    * `TokengateWeb.SupervisedServiceStatsLive` — `/services/supervised/:service_id`
      (supervisor, read-only).

  Lo compartido es el cuerpo: selector de API key, KPIs del periodo, tabla de
  API keys (`#service-api-keys-table`), pivote modelo × API key
  (`#service-model-breakdown-table`), filtros de logs
  (`#service-stats-filter-form`) y la tabla de logs en stream. Los headers,
  breadcrumbs, badges y paneles de configuración siguen siendo de cada
  LiveView.

  `load_stats/1` es la única lectura del periodo: bounds SIEMPRE de
  `Tokengate.Periods.period_bounds/2` y todo pasa por `DashboardCache`, de modo
  que dos vistas de stats comparten la misma ventana y el mismo cómputo.

  Ninguno de los LiveViews conserva copia de estos helpers: cualquier cambio de
  presentación se hace aquí (§Constraints#1).
  """

  use Phoenix.Component
  use Gettext, backend: TokengateWeb.Gettext

  import TokengateWeb.CoreComponents
  import TokengateWeb.StatsHelpers, only: [period_selector: 1]
  import Phoenix.LiveView, only: [stream: 3, stream: 4]

  alias Tokengate.Logs
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Periods
  alias TokengateWeb.KpiHelpers
  alias TokengateWeb.StatsHelpers

  @page_size 50

  ## Panel ------------------------------------------------------------------

  @doc """
  Cuerpo completo de stats del servicio.

  Todos los ids DOM son los que el admin ya publicaba
  (`#key-filter-form`, `#kpi-requests`, `#service-api-keys-table`,
  `#service-model-breakdown-table`, `#service-stats-filter-form`,
  `#service-stats-logs`, `#load-more-service-stats-logs`): los tests existentes
  dependen de ellos, así que sólo se parametrizan la URL del selector de
  periodo y los ids de la tabla de logs para las vistas que ya tenían otros.
  """
  attr :service, :map, required: true
  attr :service_api_keys, :list, required: true
  attr :key_filter_form, :any, required: true
  attr :summary, :map, required: true
  attr :key_rows, :list, required: true
  attr :model_breakdown, :map, required: true
  attr :period, :string, required: true
  attr :period_target, :string, required: true
  attr :timezone, :string, required: true
  attr :form, :any, required: true
  attr :streams, :map, required: true
  attr :has_more, :boolean, default: false
  attr :logs_id, :string, default: "service-stats-logs"
  attr :logs_empty_text, :string, default: nil
  attr :load_more_id, :string, default: "load-more-service-stats-logs"
  attr :show_service_summary, :boolean, default: true
  attr :compact_numbers, :boolean, default: false

  def panel(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Key selector + period selector --%>
      <div class="flex flex-wrap items-end justify-end gap-4">
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
        <.period_selector target={@period_target} period={@period} id="period-selector" />
      </div>

      <%!-- KPI cards (selected period) --%>
      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
        <.stat_card
          id="kpi-requests"
          label={gettext("Requests")}
          value={number(@summary.request_count, @compact_numbers)}
          sub={safe_sub_count(@summary.realtime_5min.request_count, " en 5 min")}
          icon="hero-squares-2x2"
        />
        <.stat_card
          id="kpi-cost"
          label={gettext("Cost")}
          value={fmt_money(@summary.total_cost_usd)}
          sub={safe_sub_count(@summary.request_count, " reqs")}
          icon="hero-currency-dollar"
        />
        <.stat_card
          id="kpi-input"
          label={gettext("Input tokens")}
          value={number(@summary.total_prompt_tokens, @compact_numbers)}
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
          id="kpi-output"
          label={gettext("Output tokens")}
          value={number(@summary.total_completion_tokens, @compact_numbers)}
          sub={gettext("avg TPS:") <> " " <> fmt_tps(@summary.avg_tps)}
          icon="hero-arrow-up-on-square-stack"
        />
        <.stat_card
          id="kpi-errors"
          label={gettext("Errors")}
          value={
            Integer.to_string(@summary.status_breakdown["4xx"] + @summary.status_breakdown["5xx"])
          }
          sub={safe_sub_count(@summary.realtime_5min.error_rate, "% (5 min)")}
          icon="hero-exclamation-triangle"
          tone={error_tone(@summary.status_breakdown)}
        />
        <.stat_card
          id="kpi-latency"
          label={gettext("Last request")}
          value={last_request_label(@summary.last_request_at, @timezone)}
          sub={"latency prom: " <> fmt_ms(@summary.avg_latency_ms)}
          icon="hero-clock"
        />
      </div>

      <%!-- Service + Status breakdown + Top models. show_service_summary
           hides only the Service card (its budget/config info is duplicated
           by #service-config in the supervised view); the status and top
           models cards are always rendered. --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-3">
        <div :if={@show_service_summary} class="card bg-base-100 border border-base-300 shadow-sm">
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
        <div id="status-breakdown" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <h3 class="text-sm font-semibold mb-2">{gettext("Status breakdown")}</h3>
            <div class="space-y-2">
              <.status_row class_label="2xx" count={@summary.status_breakdown["2xx"]} tone="success" />
              <.status_row class_label="4xx" count={@summary.status_breakdown["4xx"]} tone="warning" />
              <.status_row class_label="5xx" count={@summary.status_breakdown["5xx"]} tone="error" />
            </div>
          </div>
        </div>
        <div id="top-models" class="card bg-base-100 border border-base-300 shadow-sm">
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
                  <span class="flex items-center gap-2">
                    <span class="font-mono text-xs text-base-content/60">
                      {fmt_money(row.total_cost_usd)}
                    </span>
                    <span class="badge badge-sm badge-ghost">
                      {Integer.to_string(row.count)}
                    </span>
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

      <%!-- Spend per model × API key (selected period) --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body p-4">
          <h3 class="text-sm font-semibold mb-2">
            {gettext("Spend per model")} · {gettext("by API key")}
          </h3>
          <div class="overflow-x-auto">
            <table class="table table-sm" id="service-model-breakdown-table">
              <thead>
                <tr>
                  <th>{gettext("Model")}</th>
                  <th class="text-right">{gettext("Requests")}</th>
                  <th class="text-right">{gettext("Cost")}</th>
                  <th
                    :for={
                      {key_id, label} <-
                        Enum.sort_by(@model_breakdown.key_labels, fn {_id, l} -> l end)
                    }
                    class="text-right"
                  >
                    {label}
                  </th>
                </tr>
              </thead>
              <tbody>
                <%= if @model_breakdown.rows == [] do %>
                  <tr id="service-model-breakdown-empty">
                    <td class="text-center py-6 text-base-content/40" colspan="100">
                      {gettext("No requests in this period.")}
                    </td>
                  </tr>
                <% else %>
                  <tr
                    :for={row <- @model_breakdown.rows}
                    id={"model-breakdown-#{String.replace(row.model || "unknown", "/", "-")}"}
                  >
                    <td class="font-mono text-sm">{row.model || "—"}</td>
                    <td class="text-right text-sm">{format_number(row.request_count)}</td>
                    <td class="text-right text-sm font-mono">{fmt_money(row.total_cost_usd)}</td>
                    <td
                      :for={
                        {key_id, _label} <-
                          Enum.sort_by(@model_breakdown.key_labels, fn {_id, l} -> l end)
                      }
                      class="text-right text-sm font-mono"
                    >
                      {case Map.get(row.by_key, key_id) do
                        nil -> "—"
                        cell -> fmt_money(cell.total_cost_usd)
                      end}
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
        class="grid grid-cols-5 gap-3"
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
          phx-debounce="400"
        />
        <.input field={@form[:from]} type="date" label="Desde" />
        <.input field={@form[:to]} type="date" label="Hasta" />
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
          <tbody id={@logs_id} phx-update="stream">
            <tr id={"#{@logs_id}-empty"} class="hidden only:table-row">
              <td colspan="9" class="text-center py-8 text-base-content/40">
                {@logs_empty_text || gettext("No requests with the current filters.")}
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
          <button phx-click="load_more" class="btn btn-ghost btn-sm" id={@load_more_id}>
            {gettext("Load more")}
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  ## Data loading ---------------------------------------------------------

  @doc """
  Carga del periodo: summary, filas de la tabla de keys y pivote modelo × key.

  Fuente única de bounds (`Periods.period_bounds/2`) para las tres lecturas —
  dos `from` distintos mueven el borde de la ventana y la suma de la tabla deja
  de cuadrar con el KPI. Todo pasa por `DashboardCache` con llaves que incluyen
  service, periodo y timezone (y el `key_filter` en el summary).
  """
  def load_stats(socket) do
    socket
    |> assign(compute_stats_assigns(stats_params(socket.assigns)))
  end

  @doc false
  # Inputs de la carga de stats como valores planos — lo que una tarea async
  # puede capturar sin tocar el socket (`start_async` no admite assigns).
  def stats_params(assigns) do
    %{
      service_id: assigns.service.id,
      service_api_keys: assigns.service_api_keys,
      period: assigns.period,
      timezone: assigns.timezone,
      key_filter: assigns.key_filter
    }
  end

  @doc false
  def compute_stats_assigns(%{
        service_id: service_id,
        service_api_keys: api_keys,
        period: period,
        timezone: timezone,
        key_filter: key_filter
      }) do
    %{from: from} = Periods.period_bounds(period, timezone)

    # El group by de la tabla SIEMPRE es del servicio completo (una query, el
    # trim a una fila es en memoria); el summary sí se scopea por key cuando el
    # selector lo pide — y su llave de cache lleva el scope.
    key_stats =
      DashboardCache.fetch_or_compute({:service_key_stats, service_id, period, timezone}, fn ->
        Logs.service_key_stats(service_id, from: from)
      end)

    # Reporte por modelo: matriz modelo × API key (gasto del período). Se lee
    # SIEMPRE del servicio completo — el pivote en memoria recorta la columna de
    # la key cuando el selector la scopea — y comparte cache con las otras
    # lecturas del período.
    model_key_stats =
      DashboardCache.fetch_or_compute(
        {:service_model_key_stats, service_id, period, timezone},
        fn -> Logs.service_model_key_stats(service_id, from: from) end
      )

    key_rows =
      case key_filter do
        "all" ->
          build_key_rows(api_keys, key_stats)

        key_id ->
          Enum.filter(
            build_key_rows(api_keys, key_stats),
            &(&1.stats.api_key_id == key_id)
          )
      end

    summary_opts =
      if key_filter == "all" do
        [from: from]
      else
        [from: from, api_key_id: key_filter]
      end

    summary =
      DashboardCache.fetch_or_compute(
        {:service_stats, service_id, period, timezone, key_filter},
        fn -> Logs.service_stats(service_id, summary_opts) end
      )

    %{
      summary: summary,
      key_rows: key_rows,
      model_breakdown: build_model_breakdown(model_key_stats, key_rows, key_filter)
    }
  end

  @doc """
  Pivote modelo × API key en memoria: una fila por modelo (ordenado por gasto)
  con el total del período y una celda por key. La lista de columnas es la misma
  del universo de keys de la tabla de arriba (preload ∪ ids con tráfico ∪ NULL)
  — el pivote no inventa columnas.

  Con una key seleccionada el selector ya scopea el summary; la matriz se
  recorta a esa key para que las tres lecturas digan lo mismo.
  """
  def build_model_breakdown(model_key_stats, key_rows, key_filter) do
    key_labels = Map.new(key_rows, fn row -> {row.stats.api_key_id, row.label} end)

    stats =
      case key_filter do
        "all" -> model_key_stats
        key_id -> Enum.filter(model_key_stats, &(&1.api_key_id == key_id))
      end

    rows =
      stats
      |> Enum.group_by(& &1.model_requested)
      |> Enum.map(fn {model, rows} ->
        by_key = Map.new(rows, &{&1.api_key_id, &1})

        %{
          model: model,
          request_count: Enum.sum_by(rows, & &1.request_count),
          total_cost_usd: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.total_cost_usd, &2)),
          by_key: by_key
        }
      end)
      |> Enum.sort_by(&Decimal.to_float(&1.total_cost_usd), :desc)

    %{rows: rows, key_labels: key_labels}
  end

  @doc """
  Universo de la tabla de API keys: TODAS las keys del servicio (revocadas
  incluidas) ∪ los ids con tráfico del group by ∪ el grupo NULL. El join de
  labels y agregados es en memoria por `api_key_id`: el LiveView no agrega
  queries.

    * key sin tráfico en la ventana → ceros y su badge;
    * id huérfano (key borrada) → se etiqueta con el `api_key_prefix` del log,
      nunca con el uuid desnudo;
    * grupo NULL → fila "Unattributed", sólo si trae tráfico.
  """
  def build_key_rows(api_keys, key_stats) do
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

  @doc "Fila de ceros para una key sin tráfico en la ventana."
  def empty_key_stats(api_key_id) do
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

  ## Logs ------------------------------------------------------------------

  @doc """
  Carga (o pagina) la lista de logs del servicio con los filtros vigentes y el
  scope de key. `mode` es `:reset` (primera página, resetea el stream) o
  `:more` (siguiente página, preserva lo ya insertado).
  """
  def load_logs(socket, mode) do
    socket
    |> apply_logs(compute_logs(logs_params(socket.assigns), mode, socket.assigns[:cursor]), mode)
  end

  @doc false
  # Inputs de la lista de logs como valores planos (para la carga async).
  def logs_params(assigns) do
    %{
      service_id: assigns.service.id,
      filters: Map.get(assigns, :filters, default_filters()),
      key_filter: assigns[:key_filter] || "all",
      page_size: assigns[:page_size] || @page_size
    }
  end

  @doc false
  def compute_logs(params, mode, cursor) do
    base_filters =
      params.filters
      |> Map.put("service_id", params.service_id)
      |> maybe_key_filter(params.key_filter)
      |> drop_empty_filters()

    logs =
      case mode do
        :reset ->
          Logs.list_logs(Map.put(base_filters, "limit", params.page_size))

        :more ->
          cursor_filters =
            if cursor do
              Map.put(base_filters, "before", cursor)
            else
              base_filters
            end

          Logs.list_logs(Map.put(cursor_filters, "limit", params.page_size))
      end

    %{logs: logs, has_more: length(logs) == params.page_size, cursor: next_cursor(logs)}
  end

  @doc false
  # Aplica el resultado de `compute_logs/3` al socket. El cursor sólo se pisa
  # cuando llegaron filas (misma semántica que la carga síncrona original).
  def apply_logs(socket, %{logs: logs, has_more: has_more, cursor: cursor}, mode) do
    socket
    |> assign(:has_more, has_more)
    |> then(fn s -> if cursor, do: assign(s, :cursor, cursor), else: s end)
    |> then(fn s ->
      case mode do
        :reset -> stream(s, :logs, logs, reset: true)
        :more -> stream(s, :logs, logs)
      end
    end)
  end

  @doc false
  # Bundle completo de la página (stats + primera página de logs) calculado
  # como valores planos: es lo que corre dentro de `start_async/3`.
  def compute_bundle(stats_params, logs_params) do
    %{
      stats: compute_stats_assigns(stats_params),
      logs: compute_logs(logs_params, :reset, nil)
    }
  end

  @doc false
  def apply_bundle(socket, %{stats: stats, logs: logs}) do
    socket
    |> assign(stats)
    |> apply_logs(logs, :reset)
  end

  defp next_cursor([]), do: nil
  defp next_cursor(logs), do: {List.last(logs).inserted_at, List.last(logs).id}

  # Logs.list_logs/1 doesn't tolerate empty-string values for boolean fields
  # (streaming) — strip them before forwarding.
  def drop_empty_filters(filters) do
    filters
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  # El selector de key acota también la lista de logs; "all" no entra como
  # filtro (drop_empty_filters lo toleraría, pero es más claro no ponerlo).
  def maybe_key_filter(filters, "all"), do: filters

  def maybe_key_filter(filters, key_id) when is_binary(key_id),
    do: Map.put(filters, "api_key_id", key_id)

  def maybe_key_filter(filters, _), do: filters

  def default_filters do
    %{
      "status_class" => "",
      "streaming" => "",
      "from" => "",
      "to" => "",
      "model_search" => ""
    }
  end

  def default_summary do
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

  @doc """
  ¿Un log recién llegado por `logs:new` entra al stream con los filtros y el
  scope de key vigentes? Lo usan los `handle_info({:new_log, log}, …)`.
  """
  def log_matches_filters?(log, filters, timezone, key_filter) do
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

  ## Sub-components -------------------------------------------------------

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

  @doc "Número con separador de miles (o notación compacta cuando la vista lo pide)."
  def number(n, false), do: format_number(n)
  def number(n, true), do: StatsHelpers.format_compact(n)

  def format_cost(%Decimal{} = d) do
    d |> Decimal.to_float() |> :erlang.float_to_binary([:compact, {:decimals, 6}])
  end

  def format_cost(nil), do: "—"

  def format_number(n) when is_integer(n) do
    digits = Integer.to_string(abs(n))

    grouped =
      digits
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    if n < 0, do: "-" <> grouped, else: grouped
  end

  def format_number(_), do: "0"

  def fmt_money(%Decimal{} = d), do: StatsHelpers.money(d)

  def fmt_money(_), do: "$0"

  def fmt_tps(nil), do: "—"
  def fmt_tps(tps) when tps in [+0.0, -0.0, 0.0], do: "—"

  def fmt_tps(tps) when is_number(tps) do
    tps |> Float.round(1) |> :erlang.float_to_binary([:compact, {:decimals, 1}])
  end

  def fmt_tps(_), do: "—"

  def fmt_ms(nil), do: "—"
  def fmt_ms(ms) when is_number(ms), do: "#{Float.round(ms, 0) |> trunc()} ms"
  def fmt_ms(_), do: "—"

  def model_display(req, resp) do
    cond do
      is_binary(resp) and resp != "" and resp != req -> "#{req} → #{resp}"
      true -> req || "—"
    end
  end

  def status_badge(code) when is_integer(code) and code >= 200 and code < 300,
    do: "badge-success"

  def status_badge(code) when is_integer(code) and code >= 400 and code < 500,
    do: "badge-warning"

  def status_badge(code) when is_integer(code) and code >= 500 and code < 600,
    do: "badge-error"

  def status_badge(_), do: "badge-ghost"

  def last_request_label(nil, _tz), do: "—"

  def last_request_label(%DateTime{} = dt, tz),
    do: TokengateWeb.TimezoneHelper.format_datetime(dt, tz)

  defp safe_sub_count(n, suffix) when is_integer(n), do: Integer.to_string(n) <> suffix

  defp safe_sub_count(f, suffix) when is_float(f),
    do: :erlang.float_to_binary(f, [:compact, {:decimals, 1}]) <> suffix

  defp safe_sub_count(_, suffix), do: "0" <> suffix

  @doc """
  Etiqueta del gasto del servicio: ilimitado, su techo mensual, o sin
  presupuesto (solo top-ups) — el modelo no tiene suscripciones.
  """
  def limit_label(%{unlimited_spend: true}), do: "Ilimitado"

  def limit_label(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: gettext("Cap $%{amount}/month", amount: Decimal.to_string(limit))

  def limit_label(_), do: gettext("No budget")
end
