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
  import TokengateWeb.KpiHelpers, only: [kpi_card: 1]
  import TokengateWeb.StatsHelpers, only: [period_selector: 1]
  import Phoenix.LiveView, only: [stream: 3, stream: 4]

  alias Tokengate.Logs
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  alias TokengateWeb.KpiHelpers
  alias TokengateWeb.StatsHelpers
  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.FinopsCharts

  @page_size 50
  @stats_task_timeout_ms 125_000
  # El bloque realtime NO se lee dentro del agregado cacheado del periodo: su
  # ventana de 5 minutos cambia más rápido que el TTL del summary, así que va
  # en su propia query con su propio TTL corto.
  @realtime_ttl_ms 2_000

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
  attr :key_filter, :string, default: "all"
  attr :form, :any, required: true
  attr :streams, :map, required: true
  attr :has_more, :boolean, default: false
  attr :logs_empty?, :boolean, default: false
  attr :logs_id, :string, default: "service-stats-logs"
  attr :logs_empty_text, :string, default: nil
  attr :load_more_id, :string, default: "load-more-service-stats-logs"
  attr :show_service_summary, :boolean, default: true
  attr :compact_numbers, :boolean, default: false
  attr :stats_loading, :boolean, default: false
  attr :tab, :string, default: "overview"
  attr :usage_series, :list, default: []
  attr :spend_total_usd, :any, default: nil
  attr :finops_summary, :any, default: nil
  attr :finops_series, :list, default: []
  attr :finops_prev_overview, :any, default: nil
  attr :tabs, :list, required: true
  slot :config, doc: "contenidos extra del tab `Config` (config read-only del supervisado)"
  slot :finops, doc: "contenidos extra al final del tab `FinOps` (opcional)"

  def panel(assigns) do
    assigns = assign(assigns, :finops_overview, finops_overview(assigns.finops_summary))

    ~H"""
    <div class="space-y-6">
      <%!-- Toolbar: scope de key + periodo en una línea, tabs debajo del borde
           del mismo card. Ambos controles comparten eje central (`items-center`)
           así que el label del select ya no crea el escalón del layout viejo. --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="service-stats-toolbar">
        <div class="card-body p-3 gap-1">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex flex-wrap items-center gap-3">
              <span
                :if={@stats_loading}
                id="service-stats-loading"
                class="inline-flex items-center gap-1.5 text-xs text-base-content/60"
              >
                <span class="loading loading-spinner loading-xs" />
                {gettext("Loading metrics…")}
              </span>
              <.form
                :if={@service_api_keys != []}
                for={@key_filter_form}
                id="key-filter-form"
                phx-change="set_key"
                class="w-48 [&_.fieldset]:mb-0"
              >
                <.input
                  field={@key_filter_form[:key_id]}
                  type="select"
                  label={gettext("API key")}
                  class="w-full select select-sm"
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
            </div>
            <.period_selector
              target={@period_target}
              period={@period}
              id="period-selector"
              extra_query={tab_extra_query(@tab, @key_filter)}
            />
          </div>
          <div class="mt-2 -mb-1.5 tabs tabs-bordered" id="service-stats-tabs" role="tablist">
            <.link
              :for={value <- @tabs}
              id={"tab-#{value}"}
              patch={"#{@period_target}?tab=#{value}&period=#{@period}#{key_query(@key_filter)}"}
              role="tab"
              class={["tab tab-sm font-medium", tab_active?(@tab, value) && "tab-active"]}
            >
              {tab_label(value)}
            </.link>
          </div>
        </div>
      </div>

      <div
        :if={@stats_loading and @summary.request_count == 0 and @logs_empty?}
        id="service-stats-skeleton"
        class="grid grid-cols-1 sm:grid-cols-3 gap-3 animate-pulse"
      >
        <div class="h-2.5 rounded bg-base-300" />
        <div class="h-2.5 rounded bg-base-300" />
        <div class="h-2.5 rounded bg-base-300" />
      </div>

      <%!-- ============ TAB: Overview (default) ============ --%>
      <div :if={@tab == "overview"} class="space-y-6" id="service-stats-overview">
        <%!-- KPI cards (selected period) --%>
        <div class={[
          "grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-3 transition-opacity duration-150",
          @stats_loading && "opacity-60"
        ]}>
          <.kpi_card
            id="kpi-requests"
            label={gettext("Requests")}
            icon="hero-squares-2x2"
            accent="primary"
          >
            {number(@summary.request_count, @compact_numbers)}
            <:sub>
              {safe_sub_count(@summary.realtime_5min.request_count, " " <> gettext("in 5 min"))}
            </:sub>
          </.kpi_card>
          <.kpi_card
            id="kpi-cost"
            label={gettext("Cost")}
            icon="hero-currency-dollar"
            accent="accent"
          >
            {fmt_money(@summary.total_cost_usd)}
            <:sub>{cost_sub_text(@summary, @service, @period)}</:sub>
          </.kpi_card>
          <.kpi_card
            id="kpi-input"
            label={gettext("Input tokens")}
            icon="hero-arrow-down-on-square-stack"
            accent="primary"
          >
            {number(@summary.total_prompt_tokens, @compact_numbers)}
            <:sub>
              {"cached " <>
                format_number(@summary.total_cache_read_tokens) <>
                " · hit " <>
                KpiHelpers.format_hit_rate(
                  KpiHelpers.cache_hit_rate(
                    @summary.total_cache_read_tokens,
                    @summary.total_prompt_tokens
                  )
                )}
            </:sub>
          </.kpi_card>
          <.kpi_card
            id="kpi-output"
            label={gettext("Output tokens")}
            icon="hero-arrow-up-on-square-stack"
            accent="primary"
          >
            {number(@summary.total_completion_tokens, @compact_numbers)}
            <:sub>{gettext("avg TPS:") <> " " <> fmt_tps(@summary.avg_tps)}</:sub>
          </.kpi_card>
          <.kpi_card
            id="kpi-errors"
            label={gettext("Errors")}
            icon="hero-exclamation-triangle"
            accent={error_accent(@summary.status_breakdown)}
          >
            {Integer.to_string(@summary.status_breakdown["4xx"] + @summary.status_breakdown["5xx"])}
            <:sub>{period_error_sub(@summary)}</:sub>
          </.kpi_card>
          <.kpi_card
            id="kpi-latency"
            label={gettext("Last request")}
            icon="hero-clock"
            accent="neutral"
          >
            {last_request_label(@summary.last_request_at, @timezone)}
            <:sub>{gettext("avg latency:") <> " " <> fmt_ms(@summary.avg_latency_ms)}</:sub>
          </.kpi_card>
        </div>

        <%!-- Period summary: Service (admin-only) + Status breakdown. El card
           "Top models" unificó con #service-model-breakdown-table (misma
           agregación con share % y desglose por key). --%>
        <div class={[
          "grid gap-3 transition-opacity duration-150",
          if(@show_service_summary, do: "lg:grid-cols-2", else: ""),
          @stats_loading && "opacity-60"
        ]}>
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
                <.status_row class_label="5xx" count={@summary.status_breakdown["5xx"]} tone="error" />
              </div>
            </div>
          </div>
        </div>

        <%!-- Spend & requests timeline: por hora (today/yesterday) o por día
           (week/30d), apilado por modelo, con el costo por modelo en tooltip. --%>
        <.service_usage_trend
          id="service-usage-trend"
          rows={@usage_series}
          granularity={period_granularity(@period)}
          period={@period}
          total_cost={@summary.total_cost_usd}
        />

        <%!-- API keys (selected period, full universe: every key ∪ traffic ids ∪ NULL) --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <h3 class="text-sm font-semibold mb-2">{gettext("API keys")}</h3>
            <div class="overflow-x-auto">
              <.table
                id="service-api-keys-table"
                rows={@key_rows}
                row_id={fn row -> row.dom_id end}
              >
                <:col :let={row} label={gettext("Key")}>
                  <span class="font-mono text-sm">{row.label}</span>
                </:col>
                <:col :let={row} label={gettext("Status")}>
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
                </:col>
                <:col :let={row} label={gettext("Requests")} align="right">
                  <span class="text-sm font-mono">{format_number(row.stats.request_count)}</span>
                </:col>
                <:col :let={row} label={gettext("Input")} align="right">
                  <span class="text-sm">{format_number(row.stats.total_prompt_tokens)}</span>
                </:col>
                <:col :let={row} label={gettext("Output")} align="right">
                  <span class="text-sm">{format_number(row.stats.total_completion_tokens)}</span>
                </:col>
                <:col :let={row} label={gettext("Cost")} align="right">
                  <span class="text-sm font-mono">{fmt_money(row.stats.total_cost_usd)}</span>
                </:col>
                <:col :let={row} label={gettext("% of spend")} align="right">
                  <span class="text-xs tabular-nums text-base-content/60">
                    {spend_share(row.stats.total_cost_usd, spend_total(@spend_total_usd, @key_rows))}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Last request")}>
                  <span class="text-sm">{last_request_label(row.stats.last_request_at, @timezone)}</span>
                </:col>
                <:empty>
                  <div id="service-api-keys-empty">
                    <.icon name="hero-key" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                    <p>{gettext("This service has no API keys.")}</p>
                  </div>
                </:empty>
              </.table>
            </div>
          </div>
        </div>

        <%!-- Spend per model → desglose por API key debajo de cada modelo
           (selected period). <details>/<summary> = acordeón nativo, sin JS.
           Los primeros 5 modelos abren por defecto; cada sub-fila muestra el
           impacto de una key en ese modelo (reqs, tokens y costo con share). --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <h3 class="text-sm font-semibold mb-2">
              {gettext("Spend per model")} · {gettext("by API key")}
            </h3>

            <div class="overflow-x-auto">
              <div
                id="service-model-breakdown-table"
                class="min-w-[640px] divide-y divide-base-300/60"
              >
                <%!-- Column header (u-ish) del desglose --%>
                <div class="hidden md:grid grid-cols-[1.5rem_1fr_7rem_8rem_12rem] gap-3 px-2 pt-1 text-[10px] uppercase tracking-wide text-base-content/45">
                  <span />
                  <span>{gettext("Model")}</span>
                  <span class="text-right">{gettext("Requests")}</span>
                  <span class="text-right">{gettext("Cost")}</span>
                  <span class="text-right">{gettext("% of period spend")}</span>
                </div>

                <details
                  :for={{row, idx} <- Enum.with_index(@model_breakdown.rows)}
                  id={"model-breakdown-#{model_row_slug(row.model)}"}
                  class="group"
                  open={idx < 5}
                >
                  <summary class="list-none cursor-pointer grid grid-cols-[1.5rem_1fr_7rem_8rem_12rem] gap-3 items-center px-2 py-2 rounded-lg hover:bg-base-200/40">
                    <.icon
                      name="hero-chevron-right"
                      class="w-3.5 h-3.5 text-base-content/40 transition-transform t-breakdown-chevron"
                    />
                    <span class="font-mono text-sm truncate" title={row.model || "—"}>
                      {row.model || "—"}
                    </span>
                    <span class="text-sm tabular-nums text-right">
                      {format_number(row.request_count)}
                    </span>
                    <span class="font-mono text-sm text-right">{fmt_money(row.total_cost_usd)}</span>
                    <span class="flex items-center justify-end gap-2">
                      <span class="hidden sm:flex w-24 h-1.5 rounded-full bg-base-300 overflow-hidden">
                        <span
                          class="block h-full rounded-full bg-primary transition-all"
                          style={
                          "width: #{spend_share_pct(row.total_cost_usd, model_breakdown_total(@model_breakdown))}%"
                        }
                          aria-hidden="true"
                        />
                      </span>
                      <span class="text-xs tabular-nums text-base-content/60 w-12 text-right">
                        {spend_share(row.total_cost_usd, model_breakdown_total(@model_breakdown))}
                      </span>
                    </span>
                  </summary>

                  <%!-- Sub-filas: una por API key con tráfico en este modelo --%>
                  <div class="pl-10 pr-2 pb-3 space-y-1.5">
                    <div
                      :for={sub <- row.keys}
                      id={"model-breakdown-key-#{model_row_slug(row.model)}-#{sub.api_key_id || "unattributed"}"}
                      class="grid grid-cols-[2fr_3rem_6rem_6rem] sm:grid-cols-[6rem_1fr_3.5rem_6rem_5.5rem] gap-2 sm:gap-3 items-center px-2 py-1.5 rounded-lg bg-base-200/30 text-sm"
                    >
                      <span class="flex items-center gap-1.5 min-w-0">
                        <span class="font-mono text-xs truncate" title={sub.label}>
                          {sub.label}
                        </span>
                        <%= if sub.status == "revoked" do %>
                          <span class="badge badge-xs badge-error shrink-0">
                            {gettext("Revoked")}
                          </span>
                        <% end %>
                      </span>
                      <span class="tabular-nums text-xs text-base-content/70 hidden sm:inline">
                        {format_number(sub.request_count)}
                      </span>
                      <span class="text-xs tabular-nums text-base-content/60">
                        {Stats.format_compact(sub.total_prompt_tokens)} / {Stats.format_compact(
                          sub.total_completion_tokens
                        )}
                      </span>
                      <span class="font-mono text-xs">{fmt_money(sub.total_cost_usd)}</span>
                      <span class="text-xs tabular-nums text-base-content/50 text-right">
                        {spend_share(sub.total_cost_usd, row.total_cost_usd)}
                      </span>
                    </div>
                  </div>
                </details>

                <%= if @model_breakdown.rows != [] do %>
                  <%!-- Totales del período: la suma de los model rows arriba --%>
                  <div class="grid grid-cols-[1.5rem_1fr_7rem_8rem_12rem] gap-3 px-2 pt-2 text-sm font-medium">
                    <span />
                    <span>{gettext("Total")}</span>
                    <span class="tabular-nums text-right">
                      {format_number(model_breakdown_total_requests(@model_breakdown))}
                    </span>
                    <span class="font-mono">
                      {fmt_money(model_breakdown_total(@model_breakdown))}
                    </span>
                    <span class="text-xs tabular-nums text-base-content/50 text-right">100%</span>
                  </div>
                <% end %>

                <div
                  :if={@model_breakdown.rows == []}
                  id="service-model-breakdown-empty"
                  class="py-6 text-center"
                >
                  <.icon name="hero-chart-bar" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                  <p class="text-sm text-base-content/40">{gettext("No requests in this period.")}</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      <%!-- ============ TAB: FinOps ============ --%>
      <div :if={@tab == "finops"} class="space-y-6" id="service-stats-finops">
        <.finops_tab
          overview={@finops_overview}
          prev_overview={@finops_prev_overview}
          summary={@finops_summary}
          series={@finops_series}
          service={@service}
          period={@period}
          key_filter={@key_filter}
          timezone={@timezone}
        />

        <div :if={@finops != []}>
          {render_slot(@finops)}
        </div>
      </div>
      <%!-- ============ TAB: Live logs ============ --%>
      <div :if={@tab == "logs"} class="space-y-6" id="service-stats-logs-tab">
        <%!-- Filter form --%>
        <.form
          for={@form}
          id="service-stats-filter-form"
          phx-change="filter"
          class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3"
        >
          <.input
            field={@form[:status_class]}
            type="select"
            prompt={gettext("All")}
            options={[{"2xx", "2xx"}, {"4xx", "4xx"}, {"5xx", "5xx"}]}
            label={gettext("Status")}
          />
          <.input
            field={@form[:streaming]}
            type="select"
            prompt={gettext("All")}
            options={[{gettext("Yes"), "true"}, {gettext("No"), "false"}]}
            label={gettext("Streaming")}
          />
          <.input
            field={@form[:model_search]}
            type="text"
            label={gettext("Model")}
            phx-debounce="400"
          />
          <.input field={@form[:from]} type="date" label={gettext("From")} />
          <.input field={@form[:to]} type="date" label={gettext("To")} />
        </.form>

        <%!-- Logs table (stream) --%>
        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id={@logs_id}
            rows={@streams.logs}
            row_item={fn {_id, log} -> log end}
            empty?={@logs_empty?}
          >
            <:col :let={log} label={gettext("Date")}>
              <span class="whitespace-nowrap text-sm">
                {TokengateWeb.TimezoneHelper.format_datetime(log.inserted_at, @timezone)}
              </span>
            </:col>
            <:col :let={log} label={gettext("Model")}>
              <span class="text-sm">{model_display(log.model_requested, log.model_responded)}</span>
            </:col>
            <:col :let={log} label={gettext("Agent")}>
              <span class="text-sm">{log.client_agent || "—"}</span>
            </:col>
            <:col :let={log} label={gettext("Streaming")}>
              {if log.streaming, do: gettext("Yes"), else: gettext("No")}
            </:col>
            <:col :let={log} label={gettext("Status")}>
              <span class={["badge badge-sm", status_badge(log.status_code)]}>
                {Integer.to_string(log.status_code)}
              </span>
            </:col>
            <:col :let={log} label={gettext("Input")} align="right">
              <span class="text-sm">{format_number(log.prompt_tokens || 0)}</span>
            </:col>
            <:col :let={log} label={gettext("Output")} align="right">
              <span class="text-sm">{format_number(log.completion_tokens || 0)}</span>
            </:col>
            <:col :let={log} label={gettext("Cost")} align="right">
              <span class="text-sm font-mono">${format_cost(log.provider_cost_usd)}</span>
            </:col>
            <:col :let={log} label={gettext("Latency")} align="right">
              <span class="text-sm">{format_number(log.latency_ms || 0)} ms</span>
            </:col>
            <:empty>
              <.icon name="hero-inbox" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{@logs_empty_text || gettext("No requests with the current filters.")}</p>
            </:empty>
          </.table>
        </div>

        <%= if @has_more do %>
          <div class="flex justify-center">
            <button phx-click="load_more" class="btn btn-ghost btn-sm" id={@load_more_id}>
              {gettext("Load more")}
            </button>
          </div>
        <% end %>
      </div>

      <%!-- ============ TAB: Config (solo la vista supervisada lo llena) --%>
      <div :if={@tab == "config" and @config != []} id="service-stats-config-tab">
        {render_slot(@config)}
      </div>
    </div>
    """
  end

  ## FinOps tab ------------------------------------------------------------

  attr :overview, :any, required: true
  attr :prev_overview, :any, default: nil
  attr :summary, :any, default: nil
  attr :series, :list, required: true
  attr :service, :map, required: true
  attr :period, :string, required: true
  attr :key_filter, :string, required: true
  attr :timezone, :string, required: true

  # Economía del servicio scoped al periodo y a la key elegida: unit economics
  # ($/req, $/1M tok, Out/In, burn), impuestos/desperdicio (error, thinking,
  # caché) y la eficiencia por key y por modelo. La tendencia es la MISMA serie
  # de `Rollup.service_finops_series/2` que alimenta el chart del tab — una
  # lectura por bloque, nada derivado de agregados de otra ventana.
  defp finops_tab(assigns) do
    overview = assigns.overview
    prev = assigns.prev_overview

    avg_daily =
      (assigns.summary && assigns.summary[:avg_daily_cost_usd]) || Decimal.new(0)

    projection = Decimal.mult(avg_daily, Decimal.new(30))

    burn_sub =
      case days_to_cap(assigns.service, avg_daily) do
        nil ->
          gettext("proj %{proj}/30d", proj: fmt_money(projection))

        days ->
          gettext("proj %{proj}/30d · ~%{days}d to the cap",
            proj: fmt_money(projection),
            days: days
          )
      end

    by_key = (assigns.summary && assigns.summary.by_key) || []
    by_model = (assigns.summary && assigns.summary.by_model) || []

    chart_series = Enum.map(assigns.series, fn row -> Map.put(row, :subject_type, "service") end)

    assigns =
      assigns
      |> assign(:overview, overview)
      |> assign(:avg_daily, avg_daily)
      |> assign(:burn_sub, burn_sub)
      |> assign(:cpr_delta, cpr_delta(overview, prev))
      |> assign(:cpr_requests, overview.requests)
      |> assign(:out_in, Stats.out_in_ratio(overview.completion_tokens, overview.prompt_tokens))
      |> assign(:avg_in, avg_int(overview.prompt_tokens, overview.requests))
      |> assign(:avg_out, avg_int(overview.completion_tokens, overview.requests))
      |> assign(:error_share, Stats.cost_share_pct(overview.error_cost_usd, overview.cost_usd))
      |> assign(:think_share, Stats.cost_share_pct(overview.think_cost_usd, overview.cost_usd))
      |> assign(:by_key, by_key)
      |> assign(:by_model, by_model)
      |> assign(:chart_series, chart_series)
      |> assign(:hourly?, assigns.period in ["today", "yesterday"])

    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
            {gettext("FinOps")}
          </h2>
          <p class="text-xs text-base-content/50">
            {gettext(
              "Unit economics and waste · %{period} · %{scope}",
              period: Stats.period_label(@period),
              scope:
                if(@key_filter == "all", do: gettext("all API keys"), else: gettext("one API key"))
            )}
          </p>
        </div>
        <span class="font-mono text-sm font-semibold tabular-nums">
          {Stats.money(@overview.cost_usd)} · {Stats.format_number(@overview.requests)} req
        </span>
      </div>

      <%!-- Unit economics --%>
      <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3">
        <.kpi_card
          id="finops-cpr"
          label={gettext("$/req")}
          icon="hero-currency-dollar"
          accent="primary"
        >
          {Stats.cost_per_request(@overview.cost_usd, @overview.requests)}
          <:sub>
            <%= if @cpr_delta do %>
              <span class={cpr_delta_class(@cpr_delta)}>
                {KpiHelpers.delta_arrow(@cpr_delta)} {KpiHelpers.abs_float(@cpr_delta)}%
              </span>
              {gettext("vs previous period")}
            <% else %>
              {format_number(@cpr_requests)} {gettext("requests")}
            <% end %>
          </:sub>
        </.kpi_card>
        <.kpi_card id="finops-cpm" label={gettext("$/1M tok")} icon="hero-calculator" accent="accent">
          {Stats.effective_cost_per_1m(
            @overview.cost_usd,
            @overview.prompt_tokens,
            @overview.completion_tokens
          )}
          <:sub>
            {Stats.format_compact(@overview.prompt_tokens)} in / {Stats.format_compact(
              @overview.completion_tokens
            )} out
          </:sub>
        </.kpi_card>
        <.kpi_card
          id="finops-out-in"
          label={gettext("Out/In ratio")}
          icon="hero-arrows-right-left"
          accent="primary"
        >
          {@out_in}
          <:sub>
            {gettext("avg %{input} in / %{output} out per request",
              input: Stats.format_compact(@avg_in),
              output: Stats.format_compact(@avg_out)
            )}
          </:sub>
        </.kpi_card>
        <.kpi_card id="finops-burn" label={gettext("Daily burn")} icon="hero-fire" accent="warning">
          {Stats.money(@avg_daily)}
          <:sub>{@burn_sub}</:sub>
        </.kpi_card>
      </div>

      <%!-- Waste & taxes --%>
      <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-5 gap-3">
        <.kpi_card
          id="finops-error-waste"
          label={gettext("Error waste")}
          icon="hero-exclamation-triangle"
          accent="error"
        >
          {Stats.money(@overview.error_cost_usd)}
          <:sub>
            {@error_share}% {gettext("of spend")} · {format_number(@overview.error_requests)} {gettext(
              "failed"
            )}
          </:sub>
        </.kpi_card>
        <.kpi_card
          id="finops-thinking-tax"
          label={gettext("Thinking tax")}
          icon="hero-light-bulb"
          accent="accent"
        >
          {Stats.money(@overview.think_cost_usd)}
          <:sub>
            {@think_share}% {gettext("of spend")} · {format_number(@overview.think_requests)} {gettext(
              "thinking"
            )}
          </:sub>
        </.kpi_card>
        <.kpi_card
          id="finops-prompt-cache"
          label={gettext("Prompt cache")}
          icon="hero-circle-stack"
          accent="neutral"
        >
          {Stats.cache_hit_pct(@overview.prompt_tokens, @overview.cache_read_tokens)}
          <:sub>
            {Stats.format_compact(@overview.cache_read_tokens)} {gettext("read")} · {Stats.format_compact(
              @overview.cache_creation_tokens
            )} {gettext("write")}
          </:sub>
        </.kpi_card>
        <.kpi_card
          id="finops-local-cache"
          label={gettext("Local cache")}
          icon="hero-bolt"
          accent="success"
        >
          {format_number(@overview.local_cache_hits)}
          <:sub>{gettext("hits served at $0")}</:sub>
        </.kpi_card>
        <.kpi_card
          id="finops-cap"
          label={gettext("Cap vs top-ups")}
          icon="hero-banknotes"
          accent="neutral"
        >
          {limit_label(@service)}
          <:sub>
            {Stats.money(@overview.topup_cost_usd)} · {format_number(@overview.topup_requests)} {gettext(
              "top-ups"
            )}
          </:sub>
        </.kpi_card>
      </div>

      <FinopsCharts.dual_trend_chart
        id="finops-trend-chart"
        title={gettext("Spend trend")}
        hint={
          if @hourly?,
            do: gettext("hourly buckets · spend, errors and thinking tax of this service"),
            else: gettext("daily buckets · spend, errors and thinking tax of this service")
        }
        series={@chart_series}
        metric="cost"
        single_subject?={true}
        crosshair?={false}
      />

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <h3 class="text-sm font-semibold mb-2">{gettext("Efficiency by API key")}</h3>
            <div class="overflow-x-auto">
              <.table
                id="finops-key-table"
                rows={@by_key}
                row_id={fn row -> "finops-key-#{row.api_key_id || "unattributed"}" end}
              >
                <:col :let={row} label={gettext("Key")}>
                  <span class="font-mono text-xs">{row.label}</span>
                </:col>
                <:col :let={row} label={gettext("Requests")} align="right">
                  <span class="text-xs tabular-nums">{format_number(row.request_count)}</span>
                </:col>
                <:col :let={row} label={gettext("Cost")} align="right">
                  <span class="font-mono text-xs">{Stats.money(row.cost_usd)}</span>
                </:col>
                <:col :let={row} label={gettext("$/req")} align="right">
                  <span class="text-xs tabular-nums">
                    {Stats.cost_per_request(row.cost_usd, row.request_count)}
                  </span>
                </:col>
                <:col :let={row} label={gettext("$/1M tok")} align="right">
                  <span class="text-xs tabular-nums">
                    {Stats.effective_cost_per_1m(
                      row.cost_usd,
                      row.prompt_tokens,
                      row.completion_tokens
                    )}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Cache %")} align="right">
                  <span class="text-xs tabular-nums">
                    {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Error waste")} align="right">
                  <span class="text-xs tabular-nums text-error">{Stats.money(row.error_cost_usd)}</span>
                </:col>
                <:col :let={row} label={gettext("Thinking tax")} align="right">
                  <span class="text-xs tabular-nums text-accent">
                    {Stats.money(row.think_cost_usd)}
                  </span>
                </:col>
                <:empty>
                  <p class="text-sm text-base-content/40 py-4 text-center">
                    {gettext("No requests in this period.")}
                  </p>
                </:empty>
              </.table>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <h3 class="text-sm font-semibold mb-2">{gettext("Efficiency by model")}</h3>
            <div class="overflow-x-auto">
              <.table
                id="finops-model-table"
                rows={@by_model}
                row_id={fn row -> "finops-model-#{finops_model_slug(row.model_name)}" end}
              >
                <:col :let={row} label={gettext("Model")}>
                  <span class="font-mono text-xs">{row.model_name}</span>
                </:col>
                <:col :let={row} label={gettext("Requests")} align="right">
                  <span class="text-xs tabular-nums">{format_number(row.request_count)}</span>
                </:col>
                <:col :let={row} label={gettext("Cost")} align="right">
                  <span class="font-mono text-xs">{Stats.money(row.cost_usd)}</span>
                </:col>
                <:col :let={row} label={gettext("$/req")} align="right">
                  <span class="text-xs tabular-nums">
                    {Stats.cost_per_request(row.cost_usd, row.request_count)}
                  </span>
                </:col>
                <:col :let={row} label={gettext("$/1M tok")} align="right">
                  <span class="text-xs tabular-nums">
                    {Stats.effective_cost_per_1m(
                      row.cost_usd,
                      row.prompt_tokens,
                      row.completion_tokens
                    )}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Cache %")} align="right">
                  <span class="text-xs tabular-nums">
                    {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Error waste")} align="right">
                  <span class="text-xs tabular-nums text-error">{Stats.money(row.error_cost_usd)}</span>
                </:col>
                <:col :let={row} label={gettext("Thinking tax")} align="right">
                  <span class="text-xs tabular-nums text-accent">
                    {Stats.money(row.think_cost_usd)}
                  </span>
                </:col>
                <:empty>
                  <p class="text-sm text-base-content/40 py-4 text-center">
                    {gettext("No requests in this period.")}
                  </p>
                </:empty>
              </.table>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp cpr_delta(_overview, nil), do: nil

  defp cpr_delta(overview, prev) do
    with true <- overview.requests > 0,
         true <- Map.get(prev, :requests, 0) > 0,
         prev_cpr when prev_cpr > 0 <-
           Decimal.to_float(Map.get(prev, :cost_usd, Decimal.new(0))) / prev.requests do
      cur_cpr = Decimal.to_float(overview.cost_usd) / overview.requests
      Float.round((cur_cpr - prev_cpr) / prev_cpr * 100, 1)
    else
      _ -> nil
    end
  end

  # $/req sube → peor (rojo); baja → mejor (verde); plano → neutro.
  defp cpr_delta_class(delta) when is_number(delta) and delta > 0, do: "text-error"
  defp cpr_delta_class(delta) when is_number(delta) and delta < 0, do: "text-success"
  defp cpr_delta_class(_delta), do: "text-base-content/50"

  # La fila de modelo sin `model_id` (o modelo ya borrado) llega con nombre
  # "—": su id de DOM es el bucket "unknown", nunca un guion suelto.
  defp finops_model_slug(name) when name in [nil, "—"], do: "unknown"
  defp finops_model_slug(name), do: model_row_slug(name)

  defp avg_int(_tokens, requests) when requests in [0, nil], do: 0
  defp avg_int(tokens, requests), do: div(tokens || 0, requests)

  # Días hasta agotar el techo mensual al burn actual (aprox: cap / $/día).
  # Sin techo (crédito ilimitado o solo top-ups) no hay "days to cap".
  defp days_to_cap(%{monthly_spend_limit_usd: %Decimal{} = cap}, %Decimal{} = avg_daily) do
    if Decimal.compare(avg_daily, Decimal.new(0)) == :gt and
         Decimal.compare(cap, Decimal.new(0)) == :gt do
      cap |> Decimal.div(avg_daily) |> Decimal.round(0, :half_up) |> Decimal.to_integer()
    end
  end

  defp days_to_cap(_service, _avg_daily), do: nil

  ## Data loading ---------------------------------------------------------

  @doc """
  Carga del periodo: summary, filas de la tabla de keys y pivote modelo × key.

  Fuente única de bounds (`Periods.period_bounds/2`) para las tres lecturas, y
  SIEMPRE con los dos bordes: dos `from` distintos mueven el borde de la
  ventana, y un lector que sólo toma `from` suma de más toda ventana cerrada
  (ayer, mes pasado) — en ambos casos la tabla deja de cuadrar con el KPI.
  Todo pasa por `DashboardCache` con llaves que incluyen service, periodo y
  timezone (y el `key_filter` en el summary).
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
      key_filter: assigns.key_filter,
      tab: Map.get(assigns, :tab, "overview"),
      locale: Gettext.get_locale(TokengateWeb.Gettext)
    }
  end

  @doc false
  def compute_stats_assigns(
        %{
          service_id: service_id,
          service_api_keys: api_keys,
          period: period,
          timezone: timezone,
          key_filter: key_filter
        } = params
      ) do
    if locale = Map.get(params, :locale) do
      Gettext.put_locale(TokengateWeb.Gettext, locale)
    end

    # BOTH bounds: a closed window ("yesterday") read with only `from` would
    # add every request of the day after it, and the table would stop matching
    # its own KPI. One source for the pair — never two `period_bounds` calls.
    %{from: from, to: to} = Periods.period_bounds(period, timezone)
    range = [from: from, to: to]

    summary_opts =
      if key_filter == "all" do
        range
      else
        [from: from, to: to, api_key_id: key_filter]
      end

    # Run the 3 independent period aggregates concurrently; Task.async inherits
    # `$callers` so Ecto Sandbox allows it seamlessly in tests.
    key_stats_task =
      Task.async(fn ->
        DashboardCache.fetch_or_compute({:service_key_stats, service_id, period, timezone}, fn ->
          Logs.service_key_stats(service_id, [{:include_prefixes, false} | range])
        end)
      end)

    model_key_stats_task =
      Task.async(fn ->
        DashboardCache.fetch_or_compute(
          {:service_model_key_stats, service_id, period, timezone},
          fn -> Logs.service_model_key_stats(service_id, range) end
        )
      end)

    summary_core_task =
      Task.async(fn ->
        DashboardCache.fetch_or_compute(
          {:service_summary_core, service_id, period, timezone, key_filter},
          # `:realtime_5min` NO viaja dentro del agregado cacheado: su ventana
          # cambia cada segundo y el TTL del summary la congelaría. Se lee
          # aparte (`realtime_5min/3`, TTL ~2s) y se inyecta abajo.
          fn ->
            Logs.service_summary_core(service_id, summary_opts) |> Map.delete(:realtime_5min)
          end
        )
      end)

    # Query aparte para la ventana rodante de 5 min: mismo scope de servicio y
    # key, TTL corto propio (2s), así el KPI "en 5 min" nunca queda pegado a la
    # foto del periodo.
    realtime_task =
      Task.async(fn -> realtime_5min(service_id, timezone, key_filter) end)

    usage_series_task =
      Task.async(fn ->
        usage_series_rows(service_id, period, timezone, range, key_filter)
      end)

    finops? = Map.get(params, :tab) == "finops"

    finops_tasks =
      if finops? do
        [
          Task.async(fn -> finops_summary(service_id, period, timezone, key_filter, range) end),
          Task.async(fn -> finops_series(service_id, period, timezone, key_filter, range) end),
          Task.async(fn -> finops_prev_overview(service_id, period, timezone, key_filter) end)
        ]
      else
        []
      end

    [key_stats, model_key_stats, summary_core, realtime_block, usage_series | finops_results] =
      Task.await_many(
        [
          key_stats_task,
          model_key_stats_task,
          summary_core_task,
          realtime_task,
          usage_series_task
        ] ++
          finops_tasks,
        @stats_task_timeout_ms
      )

    {finops_snapshot, finops_chart, finops_prev} =
      case finops_results do
        [snapshot, chart, prev] -> {snapshot, chart, prev}
        [] -> {nil, [], nil}
      end

    known_ids = MapSet.new(api_keys, & &1.id)

    orphan_ids =
      key_stats
      |> Enum.filter(fn row ->
        not is_nil(row.api_key_id) and
          not MapSet.member?(known_ids, row.api_key_id) and
          is_nil(row[:api_key_prefix])
      end)
      |> Enum.map(& &1.api_key_id)

    orphan_prefixes =
      if orphan_ids == [] do
        %{}
      else
        Logs.api_key_prefixes_for_ids(service_id, orphan_ids, range)
      end

    all_key_rows = build_key_rows(api_keys, key_stats, orphan_prefixes)

    key_rows =
      case key_filter do
        "all" ->
          all_key_rows

        key_id ->
          Enum.filter(all_key_rows, &(&1.stats.api_key_id == key_id))
      end

    summary =
      summary_core
      |> Map.put(:top_models, top_models_from_model_key_stats(model_key_stats, key_filter))
      |> Map.put(:realtime_5min, realtime_block)
      |> Map.merge(cost_pacing(summary_core, from, to))

    %{
      summary: summary,
      key_rows: key_rows,
      model_breakdown: build_model_breakdown(model_key_stats, key_rows, key_filter),
      usage_series: usage_series,
      # Denominador de "% of spend": el gasto del servicio COMPLETO en el
      # periodo (todas las keys), no la lista filtrada — con una key
      # seleccionada la tabla mostraría 100% para su única fila.
      spend_total_usd: key_rows_total_cost(all_key_rows),
      finops_summary: finops_snapshot,
      finops_series: finops_chart,
      finops_prev_overview: finops_prev
    }
  end

  ## FinOps data ---------------------------------------------------------

  # Todas las lecturas FinOps del tab comparten la MISMA ventana del periodo y
  # el mismo scope de key que el resto del cuerpo, y pasan por `DashboardCache`
  # (igual que el summary) para que dos vistas del mismo servicio no dupliquen
  # las cuatro queries del agregado.
  defp finops_summary(service_id, period, timezone, key_filter, range) do
    DashboardCache.fetch_or_compute(
      {:service_finops_summary, service_id, period, timezone, key_filter},
      fn ->
        Rollup.service_finops_summary(service_id, Keyword.put(range, :api_key_id, key_filter))
      end
    )
  end

  defp finops_series(service_id, period, timezone, key_filter, range) do
    granularity = if period in ["today", "yesterday"], do: :hour, else: :day

    opts =
      range
      |> Keyword.put(:granularity, granularity)
      |> Keyword.put(:timezone, timezone)
      |> Keyword.put(:api_key_id, key_filter)

    DashboardCache.fetch_or_compute(
      {:service_finops_series, service_id, period, timezone, key_filter},
      fn -> Rollup.service_finops_series(service_id, opts) end
    )
  end

  # Overview del periodo ANTERIOR: sólo para el delta de `$/req`. Una query
  # (GROUPING SETS) en vez del summary completo — el resto del tab no compara.
  defp finops_prev_overview(service_id, period, timezone, key_filter) do
    %{from: from, to: to} = Periods.previous_period_bounds(period, timezone)

    DashboardCache.fetch_or_compute(
      {:service_finops_prev_overview, service_id, period, timezone, key_filter},
      fn ->
        Rollup.finops_overview(
          service_id: service_id,
          api_key_id: key_filter,
          from: from,
          to: to
        ).overall
      end
    )
  end

  # Ventana rodante de 5 minutos, fuera del agregado del periodo y con TTL
  # propio de 2s: lo que pasó en los últimos 5 min no puede quedar congelado
  # detrás de la foto del periodo (que se cachea 5s y sólo cambia con el
  # periodo/key).
  defp realtime_5min(service_id, timezone, key_filter) do
    DashboardCache.fetch_or_compute(
      {:service_realtime_5min, service_id, timezone, key_filter},
      fn ->
        filters =
          %{"service_id" => service_id}
          |> maybe_key_filter(key_filter)

        Logs.realtime_summary(filters, 300)
      end,
      ttl: @realtime_ttl_ms
    )
  end

  # Promedio diario y days/bounds del período, para el sub de la KPI de costo
  # ("$X/day avg · proj Y/30d" con crédito ilimitado, "% of cap" con techo).
  defp cost_pacing(summary_core, from, to) do
    days = max(DateTime.diff(to, from), 3600) / 86_400

    avg_daily =
      summary_core.total_cost_usd
      |> Decimal.div(Decimal.from_float(days))
      |> Decimal.round(4)

    %{period_days: days, avg_daily_cost_usd: avg_daily}
  end

  defp usage_series_rows(service_id, period, timezone, range, key_filter) do
    granularity = if period in ["today", "yesterday"], do: :hour, else: :day

    opts =
      Keyword.merge(range, granularity: granularity, timezone: timezone)

    # Coherencia de las tres lecturas: con una key seleccionada la tendencia
    # se scopia igual que summary/pivote/tabla (el PM no comparte ventanas).
    opts =
      if key_filter == "all", do: opts, else: Keyword.put(opts, :api_key_id, key_filter)

    DashboardCache.fetch_or_compute(
      {:service_usage_series, service_id, period, timezone, key_filter},
      fn ->
        Rollup.usage_series_by_model_for_service(service_id, opts)
      end
    )
  end

  defp top_models_from_model_key_stats(model_key_stats, key_filter) do
    stats =
      case key_filter do
        "all" -> model_key_stats
        key_id -> Enum.filter(model_key_stats, &(&1.api_key_id == key_id))
      end

    stats
    |> Enum.group_by(& &1.model_requested)
    |> Enum.map(fn {model_requested, rows} ->
      %{
        model_requested: model_requested,
        count: Enum.sum_by(rows, & &1.request_count),
        total_cost_usd: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.total_cost_usd, &2)),
        total_prompt_tokens: Enum.sum_by(rows, & &1.total_prompt_tokens),
        total_completion_tokens: Enum.sum_by(rows, & &1.total_completion_tokens)
      }
    end)
    |> Enum.sort(fn a, b ->
      case Decimal.compare(a.total_cost_usd, b.total_cost_usd) do
        :gt -> true
        :lt -> false
        :eq -> a.count >= b.count
      end
    end)
    |> Enum.take(5)
  end

  @doc """
  Desglose jerárquico modelo → API key en memoria: una fila por modelo
  (ordenado por gasto) con su total del período y su lista `keys` — las
  sub-filas del acordeón, ordenadas por gasto desc, con label/status y
  shares de requests ya precalculados. `key_labels` queda como mapa
  `id → %{label, status}` del universo de keys de la tabla de arriba
  (preload ∪ ids con tráfico ∪ NULL) — el pivote no inventa keys.

  Con una key seleccionada el selector ya scopea el summary; la matriz se
  recorta a esa key para que las tres lecturas digan lo mismo.
  """
  def build_model_breakdown(model_key_stats, key_rows, key_filter) do
    key_labels =
      Map.new(key_rows, fn row ->
        {row.stats.api_key_id, %{label: row.label, status: row.status}}
      end)

    stats =
      case key_filter do
        "all" -> model_key_stats
        key_id -> Enum.filter(model_key_stats, &(&1.api_key_id == key_id))
      end

    total_model_cost = fn rows ->
      Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.total_cost_usd, &2))
    end

    rows =
      stats
      |> Enum.group_by(& &1.model_requested)
      |> Enum.map(fn {model, rows} ->
        model_cost = total_model_cost.(rows)
        model_requests = Enum.sum_by(rows, & &1.request_count)

        keys =
          rows
          |> Enum.map(fn r ->
            info = key_labels[r.api_key_id] || %{label: r[:api_key_prefix] || "—", status: nil}

            %{
              api_key_id: r.api_key_id,
              label: info.label,
              status: info.status,
              request_count: r.request_count,
              total_prompt_tokens: r.total_prompt_tokens,
              total_completion_tokens: r.total_completion_tokens,
              total_cost_usd: r.total_cost_usd
            }
          end)
          |> Enum.sort_by(&Decimal.to_float(&1.total_cost_usd), :desc)

        %{
          model: model,
          request_count: model_requests,
          total_cost_usd: model_cost,
          keys: keys
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
  def build_key_rows(api_keys, key_stats, orphan_prefixes \\ %{}) do
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
          label: row[:api_key_prefix] || Map.get(orphan_prefixes, row.api_key_id) || "—",
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

  ## Usage trend (Overview) --------------------------------------------------

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :granularity, :atom, required: true
  attr :period, :string, required: true
  attr :total_cost, :any, required: true

  @doc """
  "Spend & requests" del Overview: barras apiladas por modelo (altura
  proporcional a las requests del bucket) con el costo por modelo en tooltip
  y una leyenda ordenada por gasto descendente. `granularity` es `:hour`
  (today/yesterday) o `:day` (week/30d) — lo decide el panel con el período.
  """
  def service_usage_trend(assigns) do
    rows = assigns.rows

    days =
      rows
      |> Enum.map(& &1.date)
      |> Enum.uniq()
      |> Enum.sort()

    {labels, label_totals} =
      rows
      |> Enum.group_by(& &1.label)
      |> Enum.map(fn {label, rs} ->
        {label,
         %{
           requests: Enum.sum_by(rs, & &1.request_count),
           cost: Enum.reduce(rs, Decimal.new(0), &Decimal.add(&1.total_cost_usd, &2))
         }}
      end)
      |> Enum.sort(fn {la, ta}, {lb, tb} ->
        case Decimal.compare(ta.cost, tb.cost) do
          :gt -> true
          :eq -> la >= lb
          :lt -> false
        end
      end)
      |> Enum.unzip()

    cells = Map.new(rows, fn r -> {{r.date, r.label}, r} end)

    # Total de requests por bucket (día u hora): la barra apilada se escala
    # sobre el total, no sobre la celda más alta — si no, los segmentos de un
    # bucket con varios modelos suman >100% y el apilado se recorta.
    bucket_totals = Map.new(days, fn d -> {d, bucket_total(cells, d, labels)} end)

    spark_max =
      days
      |> Enum.map(&Map.get(bucket_totals, &1, 0))
      |> Enum.max(fn -> 1 end)

    assigns =
      assigns
      |> assign(:pivoted_days, days)
      |> assign(:pivoted_labels, labels)
      |> assign(:label_totals, Map.new(Enum.zip(labels, label_totals)))
      |> assign(:cells, cells)
      |> assign(:bucket_totals, bucket_totals)
      |> assign(:spark_max, spark_max)

    ~H"""
    <%!-- La tarjeta se renderiza SIEMPRE: sin tráfico en la ventana muestra su
    empty-state (antes desaparecía sin explicación y parecía rota). --%>
    <div class="card bg-base-100 border border-base-300 shadow-sm" id={@id}>
      <div class="card-body p-4 gap-2">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-chart-bars-square-left" class="w-5 h-5 text-base-content/60" />
            {gettext("Spend & requests")}
          </h2>
          <div class="flex items-center gap-3">
            <span class="text-[10px] text-base-content/40 hidden sm:inline">
              {if @granularity == :hour, do: gettext("by hour"), else: gettext("by day")} · {Stats.period_label(
                @period
              )}
            </span>
            <span class="font-mono text-sm font-semibold tabular-nums">
              {Stats.money(@total_cost)}
            </span>
          </div>
        </div>

        <div :if={@rows == []} id={"#{@id}-empty"} class="py-6 text-center">
          <.icon name="hero-chart-bars-square-left" class="w-10 h-10 mx-auto mb-2 opacity-40" />
          <p class="text-sm text-base-content/40">{gettext("No requests in this period.")}</p>
        </div>

        <div :if={@rows != []} class="mt-2">
          <div class="flex items-end gap-px h-32 relative">
            <div
              :for={day <- @pivoted_days}
              class="flex-1 flex flex-col items-center justify-end h-full group relative"
            >
              <%!-- Tooltip: cada modelo del bucket con sus requests y su costo --%>
              <div class="hidden group-hover:block absolute -top-1 -translate-y-full left-1/2 -translate-x-1/2 z-20 pointer-events-none">
                <div class="bg-base-300 text-base-content text-[10px] rounded-md px-2 py-1 shadow-lg whitespace-nowrap">
                  <div class="font-semibold">{bucket_title(day, @granularity)}</div>
                  <div :for={label <- @pivoted_labels} class="flex justify-between gap-2">
                    <span class="truncate max-w-[130px]">{label}</span>
                    <span class="tabular-nums">{bucket_cell_text(@cells, day, label)}</span>
                  </div>
                </div>
              </div>

              <%!-- Stacked bar. `height` en la pila (no `h-full`): la barra se
              escala por el TOTAL del bucket sobre una altura definida, y cada
              segmento reparte esa altura en proporción a sus requests. Con un
              contenedor de alto automático los `height: X%` resuelven a `auto`
              y las barras miden 0px (la gráfica se ve vacía). --%>
              <div
                class="w-full flex flex-col-reverse rounded-t overflow-hidden"
                style={"height: #{bucket_bar_pct(@bucket_totals, day, @spark_max)}%"}
              >
                <div
                  :for={{label, idx} <- Enum.with_index(@pivoted_labels)}
                  class={["w-full shrink-0", Stats.sparkline_color(idx)]}
                  style={
                    "height: #{segment_pct(@cells, day, label, Map.get(@bucket_totals, day, 0))}%"
                  }
                  title={"#{label}: #{bucket_cell_text(@cells, day, label)}"}
                />
              </div>
            </div>
          </div>

          <%!-- Bucket labels (eje X) --%>
          <% bucket_count = length(@pivoted_days) %>
          <% label_step = if bucket_count > 16, do: div(bucket_count, 10) + 1, else: 1 %>
          <div class="flex gap-px mt-1">
            <span
              :for={{day, idx} <- Enum.with_index(@pivoted_days)}
              class="flex-1 text-center text-[9px] text-base-content/40 tabular-nums"
            >
              <span :if={rem(idx, label_step) == 0 or idx == bucket_count - 1}>
                {bucket_x_label(day, @granularity)}
              </span>
            </span>
          </div>
        </div>

        <%!-- Legend: modelos ordenados por gasto --%>
        <div
          :if={@pivoted_labels != []}
          class="flex flex-wrap items-center gap-x-4 gap-y-1.5 mt-2 pt-2 border-t border-base-300/60"
          id={"#{@id}-legend"}
        >
          <div
            :for={{label, idx} <- Enum.with_index(@pivoted_labels)}
            class="flex items-center gap-1.5"
          >
            <span class={["w-2 h-2 rounded-sm shrink-0", Stats.sparkline_color(idx)]} />
            <span class="text-[10px] text-base-content/70 truncate max-w-[140px]" title={label}>
              {label}
            </span>
            <span class="text-[10px] text-base-content/50 tabular-nums">
              {Stats.money(Map.get(@label_totals, label).cost)} · {Stats.format_compact(
                Map.get(@label_totals, label).requests
              )}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp bucket_total(cells, day, labels) do
    labels
    |> Enum.map(&Map.get(cells, {day, &1}))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum_by(& &1.request_count)
  end

  # Alto total de la barra del bucket: escala sqrt del total (misma curva que
  # las sparklines) para que los buckets chicos sigan leyéndose.
  defp bucket_bar_pct(bucket_totals, day, spark_max) do
    Stats.sparkline_bar_height(Map.get(bucket_totals, day, 0), spark_max)
  end

  # Reparto proporcional dentro de la barra: los segmentos del bucket suman
  # exactamente 100%, así el apilado nunca se recorta ni infla la barra.
  defp segment_pct(_cells, _day, _label, total) when total in [0, 0.0], do: 0.0

  defp segment_pct(cells, day, label, total) do
    case Map.get(cells, {day, label}) do
      nil -> 0.0
      row -> Float.round(row.request_count / total * 100, 2)
    end
  end

  defp bucket_cell_text(cells, day, label) do
    case Map.get(cells, {day, label}) do
      nil ->
        "0 · $0"

      row ->
        "#{Stats.format_compact(row.request_count)} · #{Stats.money(row.total_cost_usd)}"
    end
  end

  defp bucket_title(day, :hour), do: Calendar.strftime(day, "%H:00")
  defp bucket_title(day, _), do: Calendar.strftime(day, "%d %b")

  defp bucket_x_label(day, :hour), do: Calendar.strftime(day, "%H:00")
  defp bucket_x_label(day, _), do: Calendar.strftime(day, "%d")

  # today/yesterday → buckets por hora; week/30d → por día.
  defp period_granularity(period) when period in ["today", "yesterday"], do: :hour
  defp period_granularity(_period), do: :day

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
      timezone: Map.get(assigns, :timezone) || "Etc/UTC",
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
      |> parse_date_filters(Map.get(params, :timezone) || "Etc/UTC")

    logs =
      case mode do
        :reset ->
          Logs.list_logs_compact(Map.put(base_filters, "limit", params.page_size))

        :more ->
          cursor_filters =
            if cursor do
              Map.put(base_filters, "before", cursor)
            else
              base_filters
            end

          Logs.list_logs_compact(Map.put(cursor_filters, "limit", params.page_size))
      end

    %{logs: logs, has_more: length(logs) == params.page_size, cursor: next_cursor(logs)}
  end

  @doc false
  # Aplica el resultado de `compute_logs/3` al socket. El cursor sólo se pisa
  # cuando llegaron filas (misma semántica que la carga síncrona original).
  def apply_logs(socket, %{logs: logs, has_more: has_more, cursor: cursor}, mode) do
    # El stream no es enumerable: `.table` necesita el flag explícito para el
    # empty-state. `:reset` lo recalcula; `:more` sólo lo apaga si llegó algo.
    logs_empty? =
      case mode do
        :reset -> logs == []
        :more -> Map.get(socket.assigns, :logs_empty?, true) and logs == []
      end

    socket
    |> assign(:has_more, has_more)
    |> assign(:logs_empty?, logs_empty?)
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
  #
  # `logs_params` en `nil` = no refrescar logs: el tab Overview no baja logs
  # en su carga inicial (los trae el tab Live logs bajo demanda) y la tarea
  # de stats no se ensucia con queries que nadie está mirando.
  def compute_bundle(stats_params, logs_params) do
    logs_task =
      if logs_params do
        Task.async(fn -> compute_logs(logs_params, :reset, nil) end)
      end

    stats = compute_stats_assigns(stats_params)
    logs = if logs_task, do: Task.await(logs_task, @stats_task_timeout_ms)

    %{
      stats: stats,
      logs: logs
    }
  end

  @doc false
  # Aplica el resultado de `compute_bundle/2`. Sin logs el stream queda como
  # está (vacío o con lo que quedó del último tab de logs) — el empty-state
  # de la tabla de logs solo significa algo cuando el tab está visible.
  def apply_bundle(socket, %{stats: stats, logs: nil}) do
    assign(socket, stats)
  end

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

  defp parse_date_string(date_str, timezone, mode)

  defp parse_date_string("", _tz, _mode), do: nil
  defp parse_date_string(nil, _tz, _mode), do: nil

  # Already a datetime (programmatic callers, or a filter map that went through
  # `parse_date_filters/2`): keep it as-is.
  defp parse_date_string(%DateTime{} = dt, _tz, _mode), do: dt

  defp parse_date_string(date_str, timezone, mode) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        time =
          case mode do
            :start_of_day -> ~T[00:00:00]
            :end_of_day -> ~T[23:59:59]
          end

        local_time_to_utc(date, time, timezone)

      _ ->
        nil
    end
  end

  # Forged/odd params (`?from[]=x`) are a filter that does not apply, never a
  # crash.
  defp parse_date_string(_other, _timezone, _mode), do: nil

  # Default mode for the realtime matcher (`log_matches_filters?/4`).
  defp parse_date_string(value, timezone), do: parse_date_string(value, timezone, :start_of_day)

  # DST-safe: on a spring-forward day the local 00:00 may not exist and
  # `DateTime.new!/3` raised, which used to kill the LiveView. Fall back to the
  # first instant of the day that does exist.
  defp local_time_to_utc(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _later} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _just_before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  @doc false
  # Converts the "Desde"/"Hasta" form values (ISO dates, in the user's zone)
  # into the UTC datetimes `Logs.list_logs/1` expects. A value that doesn't
  # parse is DROPPED — the filter is ignored — instead of reaching Ecto as a
  # string, which raised `Ecto.Query.CastError` and took the socket down.
  def parse_date_filters(filters, timezone) do
    filters
    |> parse_date_filter("from", timezone, :start_of_day)
    |> parse_date_filter("to", timezone, :end_of_day)
  end

  defp parse_date_filter(filters, key, timezone, mode) do
    case Map.fetch(filters, key) do
      {:ok, value} ->
        case parse_date_string(value, timezone, mode) do
          nil -> Map.delete(filters, key)
          dt -> Map.put(filters, key, dt)
        end

      :error ->
        filters
    end
  end

  ## Sub-components -------------------------------------------------------

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

  defp row_tone("error"), do: "badge-error"
  defp row_tone("warning"), do: "badge-warning"
  defp row_tone("success"), do: "badge-success"
  defp row_tone(_), do: "badge-ghost"

  defp error_accent(%{"5xx" => n}) when n > 0, do: "error"
  defp error_accent(%{"4xx" => n}) when n > 0, do: "warning"
  defp error_accent(_), do: "neutral"

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

  defp safe_sub_count(n, suffix) when is_integer(n), do: format_number(n) <> suffix

  defp safe_sub_count(f, suffix) when is_float(f),
    do: :erlang.float_to_binary(f, [:compact, {:decimals, 1}]) <> suffix

  defp safe_sub_count(_, suffix), do: "0" <> suffix

  @doc """
  Etiqueta del gasto del servicio: ilimitado, su techo mensual, o sin
  presupuesto (solo top-ups) — el modelo no tiene suscripciones.
  """
  def limit_label(%{unlimited_spend: true}), do: gettext("Unlimited")

  def limit_label(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: gettext("Cap $%{amount}/month", amount: Decimal.to_string(limit))

  def limit_label(_), do: gettext("No budget")

  ## Tabs ------------------------------------------------------------------

  @doc """
  Tabs del detalle de un servicio — ÚNICA fuente: los dos LiveViews derivan de
  aquí su `@tabs` (lista blanca de `?tab=`) y el cuerpo compone los links.

    * `has_config?` — la vista supervisada agrega el tab Config (read-only);
    * `has_finops?` — agrega el tab FinOps (economía del gasto).
  """
  def tabs(has_config?, has_finops?) do
    ["overview"] ++
      if(has_finops?, do: ["finops"], else: []) ++
      ["logs"] ++ if(has_config?, do: ["config"], else: [])
  end

  defp tab_label("overview"), do: gettext("Overview")
  defp tab_label("finops"), do: gettext("FinOps")
  defp tab_label("logs"), do: gettext("Live logs")
  defp tab_label("config"), do: gettext("Config")
  defp tab_label(other), do: other

  # Query string del selector de periodo: conserva el tab activo y el scope de
  # key vigente, así cambiar de ventana no devuelve al Overview ni pierde la
  # key elegida.
  defp tab_extra_query("overview", "all"), do: ""
  defp tab_extra_query("overview", key_id), do: key_query(key_id)
  defp tab_extra_query(tab, "all") when is_binary(tab), do: "&tab=#{tab}"
  defp tab_extra_query(tab, key_id) when is_binary(tab), do: "&tab=#{tab}#{key_query(key_id)}"

  defp key_query("all"), do: ""
  defp key_query(key_id) when is_binary(key_id), do: "&key_id=#{key_id}"
  defp key_query(_), do: ""

  defp tab_active?(tab, value), do: tab == value

  ## Defaults ---------------------------------------------------------------

  @doc """
  Bloque cero del tab FinOps (misma forma que `Rollup.service_finops_summary/2`):
  permite montar la vista sin `nil` antes de la primera carga async.
  """
  def default_finops_summary do
    %{
      overview: zero_finops_block(),
      by_request_type: [],
      by_key: [],
      by_model: []
    }
  end

  defp finops_overview(nil), do: zero_finops_block()
  defp finops_overview(%{overview: overview}), do: overview
  defp finops_overview(block) when is_map(block), do: block

  defp zero_finops_block do
    %{
      requests: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      error_requests: 0,
      error_cost_usd: Decimal.new(0),
      fallback_recovered_count: 0,
      think_requests: 0,
      think_cost_usd: Decimal.new(0),
      local_cache_hits: 0,
      router_decision_cost_usd: Decimal.new(0),
      prompt_tokens_saved_est: 0,
      topup_requests: 0,
      topup_cost_usd: Decimal.new(0)
    }
  end

  ## KPI subs ---------------------------------------------------------------

  # Sub de la KPI de costo.
  #
  # "% del techo mensual" SOLO se lee cuando el periodo ES un mes calendario
  # ("month"/"last_month"): el techo es mensual, así que comparar el gasto de
  # una semana o de 30 días rodantes contra él da un porcentaje que no
  # significa nada. En el resto de periodos el sub es burn diario + proyección
  # a 30d (gasto ilimitado) — la pregunta real del PM: "¿a qué ritmo va?".
  # Ventanas cerradas de un día (yesterday) no proyectan: conservan el conteo.
  defp cost_sub_text(summary, %{unlimited_spend: true}, _period), do: burn_sub(summary)

  defp cost_sub_text(summary, %{monthly_spend_limit_usd: %Decimal{} = cap}, period)
       when period in ["month", "last_month"] do
    if summary[:avg_daily_cost_usd] && Decimal.compare(cap, Decimal.new(0)) == :gt do
      pct =
        Decimal.mult(Decimal.div(summary.total_cost_usd, cap), Decimal.new(100))
        |> Decimal.round(1)
        |> Decimal.to_string()

      gettext("%{pct}% of monthly cap · %{daily}/day",
        pct: pct,
        daily: fmt_money(summary.avg_daily_cost_usd)
      )
    else
      requests_sub(summary)
    end
  end

  defp cost_sub_text(summary, %{monthly_spend_limit_usd: %Decimal{}}, _period),
    do: burn_sub(summary)

  defp cost_sub_text(summary, _service, _period), do: requests_sub(summary)

  defp burn_sub(summary) do
    if summary[:avg_daily_cost_usd] && summary[:period_days] && summary.period_days >= 1 do
      proj = Decimal.mult(summary.avg_daily_cost_usd, Decimal.new(30))

      gettext("%{daily}/day · proj %{proj}/30d",
        daily: fmt_money(summary.avg_daily_cost_usd),
        proj: fmt_money(proj)
      )
    else
      requests_sub(summary)
    end
  end

  defp requests_sub(summary),
    do: safe_sub_count(summary.request_count, " " <> gettext("reqs"))

  # Sub de la KPI de errores: la tasa del período (4xx+5xx / requests), no la
  # de los últimos 5 min — el PM compara ventanas, no instantes.
  defp period_error_sub(summary) do
    total = summary.request_count

    errors = summary.status_breakdown["4xx"] + summary.status_breakdown["5xx"]

    if total > 0 do
      rate =
        (errors / total * 100)
        |> Float.round(1)
        |> :erlang.float_to_binary([:compact, {:decimals, 1}])

      "#{rate}% " <> gettext("error rate")
    else
      safe_sub_count(summary.realtime_5min.error_rate, "% (5 min)")
    end
  end

  # "441,896 reqs": el sub nunca suelta el separador de miles (el entero
  # compacto solo aplica al valor grande de la tarjeta).

  ## Shares ------------------------------------------------------------------

  defp model_row_slug(nil), do: "unknown"

  defp model_row_slug(model) when is_binary(model),
    do: String.replace(model, "/", "-")

  defp model_row_slug(other), do: to_string(other)

  @doc false
  def model_breakdown_total(%{rows: rows}) do
    Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.total_cost_usd, &2))
  end

  defp model_breakdown_total_requests(%{rows: rows}) do
    Enum.sum_by(rows, & &1.request_count)
  end

  defp key_rows_total_cost(key_rows) do
    Enum.reduce(key_rows, Decimal.new(0), &Decimal.add(&1.stats.total_cost_usd, &2))
  end

  # Denominador de "% of spend": el gasto del servicio COMPLETO en el periodo
  # (assign que manda la carga). Si no vino (render aislado), la suma de las
  # filas visibles — nunca una lista recortada por el selector de key.
  defp spend_total(%Decimal{} = total, _key_rows), do: total
  defp spend_total(_total, key_rows), do: key_rows_total_cost(key_rows)

  # "53.5%" del gasto total; sin total (período vacío) → "—" para no leer
  # como gasto cero.
  defp spend_share(%Decimal{} = cost, %Decimal{} = total) do
    if Decimal.compare(total, Decimal.new(0)) == :gt do
      spend_share_pct(cost, total) <> "%"
    else
      "—"
    end
  end

  defp spend_share(_, _), do: "—"

  defp spend_share_pct(%Decimal{} = cost, %Decimal{} = total) do
    Decimal.mult(Decimal.div(cost, total), Decimal.new(100))
    |> Decimal.round(1)
    |> Decimal.to_string()
  end
end
