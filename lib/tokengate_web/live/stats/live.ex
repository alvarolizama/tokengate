defmodule TokengateWeb.StatsLive.LiveSection do
  @moduledoc """
  Sección "En vivo" de /stats — métricas en tiempo real, org-wide.

  Cinco bloques (todos auto-refresh, mismo orden de filas que el Resumen:
  presupuesto → KPIs principales → KPIs secundarios):
    * KPIs de hoy (día calendario): costo, tokens y requests — la latencia
      (media y p95) va como sub-línea de la tarjeta de requests, que es el
      dato principal; así la fila queda en 3 columnas
    * Pulso: requests/min (5m), error rate, requests en vuelo (registry ETS
      `Logs.Inflight` — el desglose por modelo se consulta en /logs, que ya
      lista los pending con su modelo)
    * Requests por minuto — últimos 60 min (barras)
    * Hoy por hora · por proveedor — día UTC, barras apiladas (uso + quién
      lo sirve)
    * Feed: últimos requests via LiveView stream (`logs:new` + refetch)

  Sin selector de periodo: todo es "ahora".
  """
  use TokengateWeb, :html

  import TokengateWeb.KpiHelpers, only: [kpi_card: 1, format_cache_value: 2]

  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.DayHourChart

  attr :pulse, :any, required: true
  attr :today_metrics, :any, required: true
  attr :org_budget, :any, default: nil
  attr :live_drivers, :any, default: nil
  attr :yesterday_pace, :any, default: nil
  attr :chart_metric, :string, default: "requests"
  attr :minute_series, :any, required: true
  attr :minute_series_max, :any, required: true
  attr :minute_tokens_max, :any, required: true
  attr :minute_cost_max, :any, required: true
  attr :inflight_count, :any, required: true
  attr :day_by_hour, :any, required: true
  attr :last_sync_at, :any, required: true
  attr :timezone, :any, required: true
  attr :stats_loading, :any, required: true
  attr :streams, :any, required: true

  def live(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- KPIs de hoy (día calendario UTC) — primera fila de tarjetas, mismo
           orden de filas que el Resumen: KPIs principales → KPIs secundarios.
           Un solo card de gasto UTC del día (`#live-today-cost`, preservando
           `#live-org-budget-spend`), junto a Tokens y Requests con latencia. --%>
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <% today_cost =
          (@org_budget && @org_budget.daily_spend_usd) || @today_metrics.cost_usd %>
        <% pace_delta = pace_delta_pct(today_cost, @yesterday_pace) %>
        <.kpi_card
          id="live-today-cost"
          label={gettext("Today · cost (UTC)")}
          icon="hero-currency-dollar"
          accent="accent"
          title={gettext("UTC day spend (00:00–24:00 UTC)")}
        >
          <span id="live-org-budget-spend">
            ${Stats.format_decimal(today_cost)}
          </span>
          <:sub>
            {gettext("all subjects · 00:00–24:00 UTC window")}
            <span :if={@today_metrics.requests_total > 0} class="tabular-nums">
              · {Stats.cost_per_request(today_cost, @today_metrics.requests_total)}/req
            </span>
            <span
              :if={pace_delta != nil}
              id="live-yesterday-pace"
              class={[
                "font-medium tabular-nums",
                if(pace_delta > 0, do: "text-warning", else: "text-success")
              ]}
            >
              · {gettext("vs yesterday at this hour")}: {if(pace_delta >= 0, do: "+", else: "")}{pace_delta}% (${Stats.format_decimal(
                @yesterday_pace.cost_usd
              )})
            </span>
          </:sub>
        </.kpi_card>

        <.kpi_card
          id="live-today-tokens"
          label={gettext("Today · tokens")}
          icon="hero-cpu-chip"
          accent="primary"
          title={
            gettext("%{input} in / %{output} out",
              input: Stats.format_number(@today_metrics.prompt_tokens),
              output: Stats.format_number(@today_metrics.completion_tokens)
            )
          }
        >
          <span class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            {Stats.format_compact(@today_metrics.prompt_tokens)}
            <span class="text-sm text-base-content/50">in</span>
            <span class="text-base-content/30">/</span>
            {Stats.format_compact(@today_metrics.completion_tokens)}
            <span class="text-sm text-base-content/50">out</span>
            <span class="text-base-content/30">/</span>
            {format_cache_value(
              @today_metrics.cache_read_tokens,
              @today_metrics.cache_creation_tokens
            )}
            <span class="text-sm text-base-content/50">cache</span>
          </span>
          <:sub>
            {Stats.cache_hit_pct(@today_metrics.prompt_tokens, @today_metrics.cache_read_tokens)} hit
          </:sub>
        </.kpi_card>

        <%!-- Requests + latencia: el valor grande es el volumen de requests,
             que es el dato principal; la latencia (media y p95) va como
             sub-línea bajo él. Mismo criterio de ventana que el resto de la
             fila: día UTC. --%>
        <.kpi_card
          id="live-today-requests"
          label={gettext("Today · requests")}
          icon="hero-arrow-trending-up"
          accent="primary"
          title={gettext("Latency of today's requests — average and p95")}
        >
          {Stats.format_number(@today_metrics.requests_total)}
          <:sub>
            <span id="live-today-latency">
              {gettext("latency %{avg} · p95: %{p95}",
                avg: Stats.format_ms(@today_metrics.avg_latency_ms),
                p95: Stats.format_ms(@today_metrics.p95_latency_ms)
              )}
            </span>
          </:sub>
        </.kpi_card>
      </div>

      <%!-- Pulso (secundarios): req/min, error rate, en vuelo — después de
           los KPIs principales, como los secundarios del Resumen --%>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <.kpi_card
          id="live-rpm"
          label={gettext("Requests / min")}
          icon="hero-bolt"
          accent="primary"
          title={gettext("Rolling 5-minute window")}
        >
          {@pulse.req_per_min}
          <:sub>
            {gettext("%{count} requests · 5-min window",
              count: Stats.format_number(@pulse.request_count)
            )}
          </:sub>
        </.kpi_card>

        <.kpi_card
          id="live-errors"
          label={gettext("Error rate")}
          icon="hero-exclamation-triangle"
          accent="error"
        >
          {@pulse.error_rate}%
          <:sub>
            {gettext("%{count} errors in 5 min", count: Stats.format_number(@pulse.error_count))}
          </:sub>
        </.kpi_card>

        <.kpi_card
          id="live-inflight"
          label={gettext("In flight")}
          icon="hero-paper-airplane"
          accent="accent"
        >
          {Stats.format_number(@inflight_count)}
          <:sub>{gettext("requests in flight right now")}</:sub>
        </.kpi_card>
      </div>

      <%!-- Gráficas: requests / tokens / costo por minuto (últimos 60 min).
           Las tres comparten el mismo eje de 60 buckets y se dibujan siempre
           — con cero tráfico quedan como línea base plana, no como texto. --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <.minute_chart
          id="live-minute-chart"
          metric={:requests}
          icon="hero-chart-bar"
          title={gettext("Requests per minute")}
          bar_class="bg-primary/80 group-hover:bg-primary"
          series={@minute_series}
          max={@minute_series_max}
        />
        <.minute_chart
          id="live-tokens-minute-chart"
          metric={:tokens}
          icon="hero-cpu-chip"
          title={gettext("Tokens per minute")}
          bar_class="bg-accent/80 group-hover:bg-accent"
          series={@minute_series}
          max={@minute_tokens_max}
        />
        <.minute_chart
          id="live-cost-minute-chart"
          metric={:cost}
          icon="hero-currency-dollar"
          title={gettext("Cost per minute")}
          bar_class="bg-success/80 group-hover:bg-success"
          series={@minute_series}
          max={@minute_cost_max}
        />
      </div>

      <%!-- Qué cuesta ahorita (últimos 15 min): modelos, consumidores y agentes
           ordenados por gasto real para responder "¿qué está quemando presupuesto
           ahora mismo?" con un clic al detalle. --%>
      <% drivers =
        @live_drivers || %{window_minutes: 15, top_models: [], top_consumers: [], top_agents: []} %>
      <% drivers_total_cost =
        Enum.reduce(drivers.top_models, Decimal.new(0), fn m, acc ->
          Decimal.add(acc, m.cost_usd)
        end) %>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4" id="live-cost-drivers">
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-drivers-models">
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-sm font-semibold">
                <.icon name="hero-rectangle-stack" class="w-4 h-4 text-base-content/60" />
                {gettext("Active models · %{mins} min", mins: drivers.window_minutes)}
              </h2>
              <span class="text-[10px] text-base-content/40">{gettext("by cost")}</span>
            </div>
            <%= if drivers.top_models != [] do %>
              <ul class="divide-y divide-base-200/60">
                <li
                  :for={row <- drivers.top_models}
                  class="py-1.5 flex items-center justify-between gap-2 text-xs"
                >
                  <div class="min-w-0 flex-1">
                    <%= if row.model_id do %>
                      <.link
                        patch={~p"/stats/models/#{row.model_id}?period=today"}
                        class="link link-hover font-medium truncate block"
                        title={row.model_name}
                      >
                        {row.model_name}
                      </.link>
                    <% else %>
                      <span class="font-medium truncate block" title={row.model_name}>
                        {row.model_name}
                      </span>
                    <% end %>
                    <span class="text-[10px] text-base-content/50 tabular-nums">
                      {Stats.format_number(row.request_count)} req · {Stats.cache_hit_pct(
                        Map.get(row, :prompt_tokens, 0),
                        Map.get(row, :cache_read_tokens, 0)
                      )} cache
                    </span>
                  </div>
                  <div class="text-right shrink-0 font-mono tabular-nums">
                    <div class="font-semibold text-warning">
                      ${Stats.format_decimal(row.cost_usd)}
                    </div>
                    <div class="text-[10px] text-base-content/50">
                      {Stats.cost_share_pct(row.cost_usd, drivers_total_cost)}%
                    </div>
                  </div>
                </li>
              </ul>
            <% else %>
              <p class="text-xs text-base-content/40 py-4 text-center">
                {gettext("No spend in the last %{mins} min", mins: drivers.window_minutes)}
              </p>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-drivers-consumers">
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-sm font-semibold">
                <.icon name="hero-users" class="w-4 h-4 text-base-content/60" />
                {gettext("Active consumers · %{mins} min", mins: drivers.window_minutes)}
              </h2>
              <span class="text-[10px] text-base-content/40">{gettext("by cost")}</span>
            </div>
            <%= if drivers.top_consumers != [] do %>
              <ul class="divide-y divide-base-200/60">
                <li
                  :for={row <- drivers.top_consumers}
                  class="py-1.5 flex items-center justify-between gap-2 text-xs"
                >
                  <div class="min-w-0 flex-1">
                    <%= cond do %>
                      <% row.subject_type == "user" and row.subject_id -> %>
                        <.link
                          navigate={~p"/stats/users/#{row.subject_id}"}
                          class="link link-hover font-medium truncate block"
                          title={row.sublabel || row.label}
                        >
                          {row.label}
                        </.link>
                      <% row.subject_type == "service" and row.subject_id -> %>
                        <.link
                          navigate={~p"/stats/services/#{row.subject_id}"}
                          class="link link-hover font-medium truncate inline-flex items-center gap-1"
                          title={row.label}
                        >
                          <span class="truncate">{row.label}</span>
                          <span class="badge badge-xs badge-ghost shrink-0">{gettext("Service")}</span>
                        </.link>
                      <% true -> %>
                        <span class="font-medium truncate block">{row.label}</span>
                    <% end %>
                    <span class="text-[10px] text-base-content/50 tabular-nums">
                      {Stats.format_number(row.request_count)} req
                      <span :if={row.error_count > 0} class="text-warning">
                        · {row.error_count} err
                      </span>
                    </span>
                  </div>
                  <div class="text-right shrink-0 font-mono tabular-nums">
                    <div class="font-semibold text-warning">
                      ${Stats.format_decimal(row.cost_usd)}
                    </div>
                    <div class="text-[10px] text-base-content/50">
                      {Stats.cost_per_request(row.cost_usd, row.request_count)}/req
                    </div>
                  </div>
                </li>
              </ul>
            <% else %>
              <p class="text-xs text-base-content/40 py-4 text-center">
                {gettext("No spend in the last %{mins} min", mins: drivers.window_minutes)}
              </p>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-drivers-agents">
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-sm font-semibold">
                <.icon name="hero-command-line" class="w-4 h-4 text-base-content/60" />
                {gettext("Active agents · %{mins} min", mins: drivers.window_minutes)}
              </h2>
              <span class="text-[10px] text-base-content/40">{gettext("by cost")}</span>
            </div>
            <%= if drivers.top_agents != [] do %>
              <ul class="divide-y divide-base-200/60">
                <li
                  :for={row <- drivers.top_agents}
                  class="py-1.5 flex items-center justify-between gap-2 text-xs"
                >
                  <div class="min-w-0 flex-1 flex items-center gap-2">
                    <img
                      :if={row.logo}
                      src={row.logo}
                      alt=""
                      class="w-4 h-4 object-contain shrink-0"
                    />
                    <.icon
                      :if={!row.logo}
                      name={row.icon}
                      class="w-4 h-4 text-base-content/60 shrink-0"
                    />
                    <div class="min-w-0">
                      <.link
                        patch={~p"/stats/agents/#{row.key}?period=today"}
                        class="link link-hover font-medium truncate block"
                        title={row.label}
                      >
                        {row.label}
                      </.link>
                      <span class="text-[10px] text-base-content/50 tabular-nums">
                        {Stats.format_number(row.request_count)} req
                        <span :if={row.error_count > 0} class="text-warning">
                          · {row.error_count} err
                        </span>
                      </span>
                    </div>
                  </div>
                  <div class="text-right shrink-0 font-mono tabular-nums">
                    <div class="font-semibold text-warning">
                      ${Stats.format_decimal(row.cost_usd)}
                    </div>
                    <div class="text-[10px] text-base-content/50">
                      {Stats.cost_per_request(row.cost_usd, row.request_count)}/req
                    </div>
                  </div>
                </li>
              </ul>
            <% else %>
              <p class="text-xs text-base-content/40 py-4 text-center">
                {gettext("No spend in the last %{mins} min", mins: drivers.window_minutes)}
              </p>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Día en curso por hora y proveedor. Ocupa el sitio del desglose
           "en vuelo por modelo": esa tarjeta estaba vacía casi siempre (el
           registry ETS sólo tiene filas mientras hay una request en curso,
           y /logs ya lista esos pending con su modelo), así que no aportaba
           nada en el caso normal. Esta mide el día UTC completo — la misma
           ventana que los KPIs de arriba — y responde cómo va el día y
           quién lo está sirviendo. --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <%!-- Hoy por hora · por proveedor: la MISMA tarjeta que dibuja el
             Resumen sobre el período (lib/tokengate_web/live/stats/
             day_hour_chart.ex), aquí sobre el día UTC en curso. --%>
        <DayHourChart.day_hour_chart
          id="live-day-hour-chart"
          rows={@day_by_hour}
          title={gettext("Today by hour · by provider")}
          hint={
            gettext(
              "stacked bars · 1 bar = 1 hour of the UTC day · color = provider · current hour marked"
            )
          }
          hour_suffix="UTC"
          empty_note={gettext("no traffic in the UTC day yet")}
          now_hour={DateTime.utc_now().hour}
          metric={@chart_metric}
          toggle_event="set_chart_metric"
        />

        <%!-- Feed: últimos requests. La tarjeta no aporta alto propio en el
             layout de dos columnas: su cuerpo va posicionado absoluto sobre
             ella (`lg:absolute lg:inset-0`), así que quien dimensiona la fila
             es la gráfica de al lado y el feed queda exactamente de su misma
             altura, desplazándose por dentro. Sin esto, las 20 filas del feed
             estiraban la fila a ~650px y la gráfica quedaba flotando en un
             marco vacío. En una sola columna (móvil) el flujo normal manda:
             ahí no hay nada con lo que igualar. --%>
        <div
          class="card bg-base-100 border border-base-300 shadow-sm lg:relative"
          id="live-feed-card"
        >
          <div class="card-body p-4 lg:absolute lg:inset-0">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-base">
                <.icon name="hero-signal" class="w-5 h-5 text-base-content/60" /> {gettext(
                  "Last requests"
                )}
              </h2>
              <.link
                navigate={~p"/operations/monitoring"}
                class="btn btn-xs btn-ghost"
                id="live-feed-all"
              >
                {gettext("View all")} <.icon name="hero-arrow-right" class="w-3 h-3" />
              </.link>
            </div>
            <div
              id="live-feed"
              phx-update="stream"
              class="mt-3 space-y-1 overflow-y-auto lg:mt-0 lg:min-h-0 lg:flex-1"
            >
              <div
                :for={{id, log} <- @streams.live_feed}
                id={id}
                class="flex items-center justify-between gap-2 text-xs py-1 border-b border-base-200/60 last:border-0"
              >
                <span class="font-mono truncate max-w-[140px]" title={log.model_requested}>
                  {log.model_requested || "—"}
                </span>
                <span class="text-base-content/50 truncate flex-1" title={feed_who(log)}>
                  {feed_who(log)}
                </span>
                <%!-- Logo del proveedor del catálogo (models.dev): junto al
                     status, el upstream que atendió la request — sólo si la
                     log trae proveedor preloaded. --%>
                <span :if={log.provider} class="shrink-0">
                  <Stats.provider_logo logo_url={log.provider.logo_url} />
                </span>
                <span
                  :if={provider_mismatch?(log)}
                  class="shrink-0"
                  title={provider_mismatch_title(log)}
                >
                  <span class="badge badge-xs badge-warning">{provider_cause(log)}</span>
                </span>
                <span
                  :if={log.error_reason}
                  class="shrink-0 badge badge-xs badge-error"
                  title={log.error_message || log.error_reason}
                >
                  {log.error_reason}
                </span>
                <span
                  class={["shrink-0 font-mono", status_class(log.status_code)]}
                  title={gettext("Status returned to the client")}
                >
                  {log.status_code}
                </span>
                <span class="hidden sm:inline shrink-0 font-mono text-base-content/40 tabular-nums">
                  {Stats.format_ms(log.latency_ms)}
                </span>
                <span class="hidden md:inline shrink-0 font-mono text-base-content/40 tabular-nums">
                  {Stats.format_compact((log.prompt_tokens || 0) + (log.completion_tokens || 0))} tok
                </span>
                <span class="shrink-0 font-mono text-base-content/60 tabular-nums">
                  {feed_cost(log)}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # A populated bucket must never render as a zero-height bar. At a busy peak
  # (hundreds of req/min) a quiet minute with a single request rounds to 0%
  # and vanishes, which reads as "no traffic" — the opposite of what the chart
  # is for. Any non-zero value gets a visible floor; only a genuinely empty
  # bucket renders at 0.
  @min_bar_pct 2

  defp bar_height_pct(value, max) when max > 0 and value > 0 do
    (value / max * 100) |> round() |> max(@min_bar_pct)
  end

  defp bar_height_pct(_value, _max), do: 0

  ## Gráficas por minuto ---------------------------------------------------

  attr :id, :string, required: true
  attr :metric, :atom, required: true, values: [:requests, :tokens, :cost]
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :bar_class, :string, required: true
  attr :series, :list, required: true
  attr :max, :any, required: true

  # Bar chart card for one metric of the shared 60-minute series. Renders the
  # full window even with zero traffic so the axis stays readable.
  defp minute_chart(assigns) do
    assigns =
      assigns
      |> assign(:has_data?, assigns.max > 0)
      |> assign(:avg, mean_per_minute(assigns.metric, assigns.series))

    ~H"""
    <div class="card bg-base-100 border border-base-300 shadow-sm" id={@id}>
      <div class="card-body p-4 gap-2">
        <div class="flex items-center justify-between gap-2">
          <h2 class="card-title text-base">
            <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
            {@title}
          </h2>
          <%!-- El pico solo no dice cómo fue la hora: un único minuto cargado
               al lado de 59 vacíos y una hora sostenida se ven idénticos.
               El promedio por minuto de la ventana va al lado para que la
               forma de la hora se lea de un vistazo. --%>
          <span
            :if={@has_data?}
            class="text-xs text-base-content/40 tabular-nums"
            id={"#{@id}-header-stats"}
            title={
              gettext(
                "avg: mean per minute of the whole window (minutes without traffic count as 0) · peak: busiest minute"
              )
            }
          >
            {gettext("avg")} {metric_avg(@metric, @avg)} · {gettext("peak")} {metric_peak(
              @metric,
              @max
            )}
          </span>
        </div>

        <%!-- Tipo de gráfica y unidad explícitos: son barras, una por minuto,
             sobre la ventana fija de 60 min. --%>
        <p class="text-[10px] text-base-content/40" id={"#{@id}-hint"}>
          {gettext("bars · 1 bar = 1 min · last 60 min")}
        </p>

        <div class="flex items-end gap-px h-40 mt-2">
          <div
            :for={row <- @series}
            class="flex-1 group relative flex items-end h-full"
            title={bucket_title(row, @metric)}
          >
            <div
              class={["w-full rounded-t transition-colors", @bar_class]}
              style={"height: #{bar_height_pct(metric_value(row, @metric), @max)}%"}
            >
            </div>
          </div>
        </div>

        <div class="flex items-center justify-between text-[10px] text-base-content/40">
          <span>-60 min</span>
          <span :if={not @has_data?} class="text-base-content/30">{gettext(
            "no traffic in the last hour"
          )}</span>
          <span>{gettext("now")}</span>
        </div>
      </div>
    </div>
    """
  end

  defp metric_value(row, :requests), do: row.request_count
  defp metric_value(row, :tokens), do: row.prompt_tokens + row.completion_tokens
  defp metric_value(row, :cost), do: Decimal.to_float(row.cost_usd)

  defp bucket_title(row, :cost) do
    gettext("%{dt} · $%{cost}",
      dt: Stats.format_dt(row.bucket),
      cost: Stats.format_decimal(Decimal.round(row.cost_usd, 6))
    )
  end

  defp bucket_title(row, :tokens) do
    gettext("%{dt} · %{input} in / %{output} out",
      dt: Stats.format_dt(row.bucket),
      input: Stats.format_number(row.prompt_tokens),
      output: Stats.format_number(row.completion_tokens)
    )
  end

  defp bucket_title(row, :requests) do
    gettext("%{dt} · %{count} req",
      dt: Stats.format_dt(row.bucket),
      count: Stats.format_number(row.request_count)
    )
  end

  defp metric_peak(:requests, max),
    do: gettext("%{count} req/min", count: Stats.format_number(max))

  defp metric_peak(:tokens, max),
    do: gettext("%{count} tok/min", count: Stats.format_compact(max))

  defp metric_peak(:cost, max), do: "$#{Float.round(max, 4)}/min"

  # Media por minuto de la ventana. El denominador es la ventana completa (los
  # buckets vacíos cuentan como 0): es "cuánto por minuto, de media, en la
  # última hora". La media de sólo los minutos con tráfico sería otra cosa —la
  # media de los minutos activos— y al lado del pico se leería como un segundo
  # pico.
  defp mean_per_minute(_metric, []), do: 0.0

  defp mean_per_minute(metric, series) do
    total =
      Enum.reduce(series, 0.0, fn row, acc -> acc + metric_value(row, metric) end)

    total / length(series)
  end

  # Una decimal para requests (5 requests en 60 min son 0.1/min, y truncar a 0
  # haría parecer la tarjeta vacía), entero para tokens —que a estas escalas se
  # leen mejor compactos— y seis decimales para el coste, donde el pico —que va
  # a cuatro— redondearía a cero una hora con gasto real.
  defp metric_avg(:requests, avg), do: "#{format_avg(avg, 1)} req/min"

  defp metric_avg(:tokens, avg),
    do: gettext("%{count} tok/min", count: Stats.format_compact(round(avg)))

  defp metric_avg(:cost, avg), do: "$#{format_avg(avg, 6)}/min"

  defp format_avg(value, decimals) do
    :erlang.float_to_binary(value * 1.0, decimals: decimals)
  end

  defp status_class(code) when code >= 400, do: "text-warning"
  defp status_class(_code), do: "text-success"

  # El número del feed es el status que TokenGate devolvió AL CLIENTE
  # (`status_code`), no el del proveedor. Cuando el proveedor contestó algo
  # distinto — típicamente un fallback que recuperó la request (provider 429/5xx
  # pero cliente 200) — mostramos la causa del upstream a la izquierda del
  # status, para que un 200 no oculte el error real.
  defp provider_mismatch?(%{provider_status_code: nil}), do: false

  defp provider_mismatch?(%{provider_status_code: provider, status_code: client}) do
    provider != client
  end

  defp provider_cause(%{provider_status_code: provider}), do: "prov #{provider}"

  defp provider_mismatch_title(%{provider_status_code: provider, status_code: client}) do
    gettext("The provider answered %{provider}; the client received %{client}",
      provider: provider,
      client: client
    ) <>
      if(client == 200, do: gettext(" (recovered by fallback)"), else: "")
  end

  defp feed_who(%{subject_type: "service", service: %{name: name}}), do: "svc · #{name}"
  defp feed_who(%{group_member: %{user: %{email: email}}}), do: email
  defp feed_who(%{group_member_id: nil}), do: "—"
  defp feed_who(_log), do: "—"

  defp feed_cost(%{provider_cost_usd: %Decimal{} = d}) do
    "$" <> Stats.format_decimal(Decimal.round(d, 4))
  end

  defp feed_cost(_log), do: "$0"

  defp pace_delta_pct(_today_cost, nil), do: nil

  defp pace_delta_pct(%Decimal{} = today_cost, %{cost_usd: %Decimal{} = prev_cost}) do
    if Decimal.compare(prev_cost, Decimal.new(0)) == :gt do
      today_cost
      |> Decimal.sub(prev_cost)
      |> Decimal.div(prev_cost)
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.round(1, :half_up)
      |> Decimal.to_float()
    else
      nil
    end
  end

  defp pace_delta_pct(_, _), do: nil
end
