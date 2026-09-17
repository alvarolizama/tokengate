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
  attr :minute_series, :any, required: true
  attr :minute_series_max, :any, required: true
  attr :minute_tokens_max, :any, required: true
  attr :minute_cost_max, :any, required: true
  attr :inflight_count, :any, required: true
  attr :day_by_hour, :any, required: true
  attr :last_sync_at, :any, required: true
  attr :timezone, :any, required: true
  attr :budget_reset_hours, :any, required: true
  attr :budget_reset_minutes, :any, required: true
  attr :budget_reset_at, :any, required: true
  attr :stats_loading, :any, required: true
  attr :streams, :any, required: true

  def live(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Tope diario global — gasto real del día UTC (misma fuente y misma
           ventana que Mantenimiento) vs kill-switch diario, que resetea a las
           00:00 UTC. Día UTC y no local: si el número midiera el día local, la
           barra y el countdown apuntarían a ventanas distintas. Sin contador
           ETS: ese incluye holds en vuelo y oscila con el tráfico en curso. --%>
      <%= if @org_budget do %>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-org-budget">
          <div class="card-body p-5">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <div class="flex items-center gap-2">
                <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Tope diario global
                </span>
                <Stats.budget_badge pct={@org_budget.daily_pct} />
              </div>
              <span
                :if={@org_budget.exempt_count > 0}
                class="badge badge-sm badge-ghost"
                id="live-org-budget-exempt"
                title="Usuarios, perfiles de límites o servicios exentos del tope diario global"
              >
                {@org_budget.exempt_count} exentos
              </span>
            </div>
            <div class="mt-2">
              <Stats.budget_bar
                spend={@org_budget.daily_spend_usd}
                limit={@org_budget.daily_cap_usd}
                pct={@org_budget.daily_pct}
              />
            </div>
            <p class="text-xs text-base-content/40 mt-1">
              Gasto del día UTC · todos los sujetos · reinicia en
              <span
                class="font-mono tabular-nums text-base-content/60 whitespace-nowrap"
                id="live-budget-reset-countdown"
                title="Horas y minutos restantes hasta el reinicio del tope (00:00 UTC)"
                aria-label={
                  "Faltan #{@budget_reset_hours} horas y #{@budget_reset_minutes} minutos para el reinicio del tope"
                }
              >
                <span aria-hidden="true">
                  {@budget_reset_hours}<span class="reset-colon">:</span>{@budget_reset_minutes}<span class="text-base-content/40">h</span>
                </span>
              </span>
              <span id="live-budget-reset-at">
                ({Stats.format_time(@budget_reset_at, @timezone)} en tu hora local)
              </span>
            </p>
          </div>
        </div>
      <% end %>

      <%!-- KPIs de hoy (día calendario) — primera fila de tarjetas, mismo
           orden de filas que el Resumen: presupuesto → KPIs principales →
           KPIs secundarios. Dentro de la fila: Costo · Tokens · Requests con
           la latencia debajo (3 columnas: requests y latencia comparten
           tarjeta porque son la misma lectura — volumen y su coste en
           tiempo — y así la fila no deja un hueco vacío). --%>
      <div class="grid grid-cols-2 lg:grid-cols-3 gap-4">
        <.kpi_card
          id="live-today-cost"
          label="Hoy · costo (UTC)"
          icon="hero-currency-dollar"
          accent="accent"
          title="Gasto del día UTC (00:00–24:00 UTC) — la ventana que reinicia el tope global"
        >
          ${Stats.format_decimal(@today_metrics.cost_usd)}
          <:sub>
            Reinicia en {@budget_reset_hours}h {@budget_reset_minutes}m
            ({Stats.format_time(@budget_reset_at, @timezone)} en tu hora local)
          </:sub>
        </.kpi_card>

        <.kpi_card
          id="live-today-tokens"
          label="Hoy · tokens"
          icon="hero-cpu-chip"
          accent="primary"
          title={
            "#{Stats.format_number(@today_metrics.prompt_tokens)} in / #{Stats.format_number(@today_metrics.completion_tokens)} out"
          }
        >
          <span class="flex items-baseline gap-2">
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
          label="Hoy · requests"
          icon="hero-arrow-trending-up"
          accent="primary"
          title="Latencia de las requests de hoy — media y p95"
        >
          {Stats.format_number(@today_metrics.requests_total)}
          <:sub>
            <span id="live-today-latency">
              latencia {Stats.format_ms(@today_metrics.avg_latency_ms)} · p95: {Stats.format_ms(
                @today_metrics.p95_latency_ms
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
          label="Requests / min"
          icon="hero-bolt"
          accent="primary"
          title="Ventana móvil de 5 minutos"
        >
          {@pulse.req_per_min}
          <:sub>ventana 5 min · {Stats.format_number(@pulse.request_count)} requests</:sub>
        </.kpi_card>

        <.kpi_card
          id="live-errors"
          label="Tasa de error"
          icon="hero-exclamation-triangle"
          accent="error"
        >
          {@pulse.error_rate}%
          <:sub>{Stats.format_number(@pulse.error_count)} errores en 5 min</:sub>
        </.kpi_card>

        <.kpi_card
          id="live-inflight"
          label="En vuelo"
          icon="hero-paper-airplane"
          accent="accent"
        >
          {Stats.format_number(@inflight_count)}
          <:sub>requests en curso ahora</:sub>
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
          title="Requests por minuto"
          bar_class="bg-primary/80 group-hover:bg-primary"
          series={@minute_series}
          max={@minute_series_max}
        />
        <.minute_chart
          id="live-tokens-minute-chart"
          metric={:tokens}
          icon="hero-cpu-chip"
          title="Tokens por minuto"
          bar_class="bg-accent/80 group-hover:bg-accent"
          series={@minute_series}
          max={@minute_tokens_max}
        />
        <.minute_chart
          id="live-cost-minute-chart"
          metric={:cost}
          icon="hero-currency-dollar"
          title="Costo por minuto"
          bar_class="bg-success/80 group-hover:bg-success"
          series={@minute_series}
          max={@minute_cost_max}
        />
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
          title="Hoy por hora · por proveedor"
          hint="barras apiladas · 1 barra = 1 hora del día UTC · color = proveedor · hora en curso marcada"
          hour_suffix="UTC"
          empty_note="sin tráfico en el día UTC todavía"
          now_hour={DateTime.utc_now().hour}
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
                <.icon name="hero-signal" class="w-5 h-5 text-base-content/60" /> Últimos requests
              </h2>
              <.link
                navigate={~p"/operations/monitoring"}
                class="btn btn-xs btn-ghost"
                id="live-feed-all"
              >
                Ver todos <.icon name="hero-arrow-right" class="w-3 h-3" />
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
                  title="Status devuelto al cliente"
                >
                  {log.status_code}
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
            title="prom.: media por minuto de la ventana completa (los minutos sin tráfico cuentan como 0) · pico: minuto de mayor tráfico"
          >
            prom. {metric_avg(@metric, @avg)} · pico {metric_peak(@metric, @max)}
          </span>
        </div>

        <%!-- Tipo de gráfica y unidad explícitos: son barras, una por minuto,
             sobre la ventana fija de 60 min. --%>
        <p class="text-[10px] text-base-content/40" id={"#{@id}-hint"}>
          barras · 1 barra = 1 min · últimos 60 min
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
          <span :if={not @has_data?} class="text-base-content/30">sin tráfico en la última hora</span>
          <span>ahora</span>
        </div>
      </div>
    </div>
    """
  end

  defp metric_value(row, :requests), do: row.request_count
  defp metric_value(row, :tokens), do: row.prompt_tokens + row.completion_tokens
  defp metric_value(row, :cost), do: Decimal.to_float(row.cost_usd)

  defp bucket_title(row, :cost) do
    "#{Stats.format_dt(row.bucket)} · $#{Stats.format_decimal(Decimal.round(row.cost_usd, 6))}"
  end

  defp bucket_title(row, :tokens) do
    "#{Stats.format_dt(row.bucket)} · #{Stats.format_number(row.prompt_tokens)} in / " <>
      "#{Stats.format_number(row.completion_tokens)} out"
  end

  defp bucket_title(row, :requests) do
    "#{Stats.format_dt(row.bucket)} · #{Stats.format_number(row.request_count)} req"
  end

  defp metric_peak(:requests, max), do: "#{Stats.format_number(max)} req/min"
  defp metric_peak(:tokens, max), do: "#{Stats.format_compact(max)} tok/min"
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
  defp metric_avg(:tokens, avg), do: "#{Stats.format_compact(round(avg))} tok/min"
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
    "El proveedor respondió #{provider}; el cliente recibió #{client}" <>
      if(client == 200, do: " (recuperada por fallback)", else: "")
  end

  defp feed_who(%{subject_type: "service", service: %{name: name}}), do: "svc · #{name}"
  defp feed_who(%{group_member: %{user: %{email: email}}}), do: email
  defp feed_who(%{group_member_id: nil}), do: "—"
  defp feed_who(_log), do: "—"

  defp feed_cost(%{provider_cost_usd: %Decimal{} = d}) do
    "$" <> Stats.format_decimal(Decimal.round(d, 4))
  end

  defp feed_cost(_log), do: "$0"
end
