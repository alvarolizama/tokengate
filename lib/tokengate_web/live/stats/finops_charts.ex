defmodule TokengateWeb.StatsLive.FinopsCharts do
  @moduledoc """
  Gráficas de la pestaña FinOps (`/stats/finops`).

  Todo es **SVG escrito a mano en HEEx** (DESIGN §C9): sin librerías de
  charting, escalas calculadas en el servidor y colores del tema. Cada
  componente es una tarjeta cerrada con su `id` estable para los tests.

    * `dual_trend_chart/1` — tendencia de dos series (Usuarios vs Servicios)
      o una sola cuando el sujeto es único; también el modo `$/req`.
    * `spend_anatomy_bar/1` — barra 100% apilada: a dónde fue cada dólar
      (útil, impuesto de pensamiento, desperdicio por error, overhead del
      router), con las píldoras de caché y top-ups.
    * `capability_bars/1` — barras horizontales por `request_type`.
    * `efficiency_scatter/1` — mapa de cuadrantes requests × `$/req`
      facturable (o caché), radio por costo, mediana por grupo como línea de
      corte y lista de los sujetos eficientes, con enlace a su detalle.
  """

  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  # Lienzo del gráfico de tendencia. El SVG se estira con
  # `preserveAspectRatio="none"` y las etiquetas de los ejes viven en HTML,
  # como en `DayHourChart` (así el texto no se deforma).
  @chart_w 600
  @chart_h 176
  @pad_x 8
  @pad_top 10
  @pad_bottom 14

  # Lienzo de la dispersión. Acá sí hay texto dentro del SVG, así que se
  # conserva la proporción (`meet`) y los círculos no se vuelven elipses.
  @scatter_w 600
  @scatter_h 220
  @scatter_left 58
  @scatter_right 12
  @scatter_top 10
  @scatter_bottom 26

  ## Tendencia -------------------------------------------------------------

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :series, :list, required: true
  attr :metric, :string, default: "cost"
  attr :toggle_event, :string, default: nil
  attr :single_subject?, :boolean, default: false
  attr :crosshair?, :boolean, default: true

  def dual_trend_chart(assigns) do
    metric = if assigns.metric in ~w(cost requests cpr), do: assigns.metric, else: "cost"
    buckets = build_buckets(assigns.series)

    types = assigns.series |> Enum.map(& &1.subject_type) |> Enum.uniq()

    # Sujeto único (p. ej. el detalle de un servicio): no hay serie de
    # usuarios, la primaria son los servicios.
    single? = assigns.single_subject? or "user" not in types

    rows =
      Enum.map(buckets, fn bucket ->
        primary =
          cond do
            metric == "cpr" -> metric_value(total_agg(bucket), metric)
            single? -> metric_value(bucket.services, metric)
            true -> metric_value(bucket.users, metric)
          end

        secondary =
          cond do
            metric == "cpr" -> nil
            single? -> nil
            "service" in types -> metric_value(bucket.services, metric)
            true -> nil
          end

        %{label: bucket.label, primary: primary, secondary: secondary}
      end)

    max =
      rows
      |> Enum.flat_map(fn row -> [row.primary, row.secondary] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0.0 end)

    has_data? = rows != [] and max > 0

    scale_max = axis_ceiling(max, metric)

    primary_label =
      cond do
        metric == "cpr" -> gettext("$/req")
        single? -> gettext("Services")
        true -> gettext("Users")
      end

    secondary_label = gettext("Services")

    points = layout_points(rows, scale_max)
    bands = hover_bands(points, length(rows), metric, primary_label, secondary_label, single?)

    assigns =
      assigns
      |> assign(:metric, metric)
      |> assign(:rows, rows)
      |> assign(:points, points)
      |> assign(:bands, bands)
      |> assign(:has_data?, has_data?)
      |> assign(:scale_max, scale_max)
      |> assign(:ticks, axis_ticks(scale_max))
      |> assign(:primary_label, primary_label)
      |> assign(:secondary_label, secondary_label)
      |> assign(:secondary?, not single? and "service" in types and metric != "cpr")
      |> assign(:x_labels, x_labels(points))

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-2">
        <div class="flex items-center justify-between flex-wrap gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-chart-bar" class="w-5 h-5 text-base-content/60" />
            {@title}
          </h2>
          <div :if={@toggle_event} class="join" id={"#{@id}-metric-toggle"}>
            <button
              :for={
                {value, label} <- [
                  {"cost", gettext("Cost")},
                  {"requests", gettext("Requests")},
                  {"cpr", gettext("$/req")}
                ]
              }
              type="button"
              phx-click={@toggle_event}
              phx-value-metric={value}
              class={[
                "btn btn-xs join-item",
                if(@metric == value, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <p :if={@hint} class="text-[10px] leading-snug text-base-content/40">{@hint}</p>

        <div
          :if={not @has_data?}
          class="h-44 flex items-center justify-center text-base-content/40 text-sm"
        >
          {gettext("No data in this period.")}
        </div>

        <div :if={@has_data?} class="mt-2">
          <div class="flex gap-2 items-stretch">
            <div class="relative w-12 shrink-0 h-44">
              <span
                :for={tick <- @ticks}
                class="absolute right-0 text-[9px] leading-none text-base-content/50 tabular-nums -translate-y-1/2"
                style={"bottom: #{tick_bottom_pct(tick, @scale_max)}%"}
              >
                {format_axis(tick, @metric)}
              </span>
              <span class="absolute right-0 bottom-0 text-[9px] leading-none text-base-content/50 tabular-nums translate-y-1/2">
                {format_axis(0, @metric)}
              </span>
            </div>

            <div
              class="relative flex-1 h-44"
              id={"#{@id}-hover"}
              phx-hook={@crosshair? && ".FinopsCrosshair"}
            >
              <svg
                viewBox="0 0 600 176"
                class="w-full h-44"
                preserveAspectRatio="none"
                role="img"
                aria-label={@title}
              >
                <line
                  :for={tick <- @ticks}
                  x1="0"
                  x2="600"
                  y1={y_pos(tick, @scale_max)}
                  y2={y_pos(tick, @scale_max)}
                  class="stroke-base-300/60"
                  stroke-width="1"
                  stroke-dasharray="3 4"
                />

                <path d={area_path(@points, :primary)} class="fill-primary/10" />
                <path
                  d={line_path(@points, :primary)}
                  class="stroke-primary"
                  fill="none"
                  stroke-width="2"
                  stroke-linejoin="round"
                  stroke-linecap="round"
                />

                <g :if={@secondary?}>
                  <path d={area_path(@points, :secondary)} class="fill-warning/10" />
                  <path
                    d={line_path(@points, :secondary)}
                    class="stroke-warning"
                    fill="none"
                    stroke-width="2"
                    stroke-linejoin="round"
                    stroke-linecap="round"
                  />
                </g>

                <line
                  data-crosshair
                  x1="0"
                  x2="0"
                  y1="0"
                  y2="176"
                  class="stroke-base-content/40"
                  stroke-width="1"
                  stroke-dasharray="2 3"
                  style="display: none"
                />

                <rect
                  :for={band <- @bands}
                  x={band.x}
                  y="0"
                  width={band.width}
                  height="176"
                  fill="transparent"
                  data-x={band.cx}
                  data-tip={band.tip}
                  class="hover:fill-base-content/5"
                >
                  <title>{band.tip}</title>
                </rect>
              </svg>

              <div
                data-tip-box
                class="hidden absolute z-10 -translate-x-1/2 -translate-y-full pointer-events-none bg-base-300 text-base-content text-[10px] rounded-md px-2 py-1 shadow-lg whitespace-nowrap"
              >
              </div>
            </div>
          </div>

          <div class="relative h-4 mt-1 ml-14" id={"#{@id}-dates"}>
            <span
              :for={label <- @x_labels}
              class="absolute top-0 -translate-x-1/2 text-[9px] text-base-content/40 tabular-nums whitespace-nowrap"
              style={"left: #{label.left}%"}
            >
              {label.text}
            </span>
          </div>

          <div
            class="flex flex-wrap items-center gap-x-4 gap-y-1 mt-2 pt-2 border-t border-base-300/60"
            id={"#{@id}-legend"}
          >
            <div class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-sm shrink-0 bg-primary" />
              <span class="text-[10px] text-base-content/60">{@primary_label}</span>
            </div>
            <div :if={@secondary?} class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-sm shrink-0 bg-warning" />
              <span class="text-[10px] text-base-content/60">{@secondary_label}</span>
            </div>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".FinopsCrosshair">
          // Lectura de la serie bajo el cursor: mueve la línea vertical y
          // reescribe la burbuja. Sin estado de servidor y sin re-render.
          export default {
            mounted() {
              const svg = this.el.querySelector("svg")
              if (!svg) return
              this.svg = svg
              this.line = svg.querySelector("[data-crosshair]")
              this.tip = this.el.querySelector("[data-tip-box]")
              this.bands = Array.from(svg.querySelectorAll("[data-x]"))
              if (!this.bands.length) return

              this.onMove = (event) => {
                const rect = svg.getBoundingClientRect()
                if (!rect.width) return
                const vx = ((event.clientX - rect.left) / rect.width) * 600
                let best = this.bands[0]
                let bestDist = Infinity
                for (const band of this.bands) {
                  const dist = Math.abs(parseFloat(band.dataset.x) - vx)
                  if (dist < bestDist) {
                    bestDist = dist
                    best = band
                  }
                }
                const x = parseFloat(best.dataset.x)
                if (this.line) {
                  this.line.setAttribute("x1", x)
                  this.line.setAttribute("x2", x)
                  this.line.style.display = ""
                }
                if (this.tip && best.dataset.tip) {
                  this.tip.textContent = best.dataset.tip
                  this.tip.style.left = (x / 600) * 100 + "%"
                  this.tip.classList.remove("hidden")
                }
              }

              this.onLeave = () => {
                if (this.line) this.line.style.display = "none"
                if (this.tip) this.tip.classList.add("hidden")
              }

              this.el.addEventListener("mousemove", this.onMove)
              this.el.addEventListener("mouseleave", this.onLeave)
            },
            destroyed() {
              if (this.onMove) this.el.removeEventListener("mousemove", this.onMove)
              if (this.onLeave) this.el.removeEventListener("mouseleave", this.onLeave)
            }
          }
        </script>
      </div>
    </div>
    """
  end

  ## Anatomía del gasto ----------------------------------------------------

  attr :id, :string, required: true
  attr :overview, :any, required: true
  attr :title, :string, default: nil
  attr :single_subject?, :boolean, default: false
  attr :users_useful_cost, :any, default: :derive

  def spend_anatomy_bar(assigns) do
    overview = normalize_overview(assigns.overview)
    overall = overview.overall
    raw_users = if is_map(assigns.overview), do: Map.get(assigns.overview, :users)
    raw_services = if is_map(assigns.overview), do: Map.get(assigns.overview, :services)
    users = raw_users || zero_block()
    services = raw_services || zero_block()

    single? = assigns.single_subject? or is_nil(assigns.users_useful_cost) or is_nil(raw_users)

    subject = if single?, do: raw_services || overall, else: nil

    users_useful =
      cond do
        single? -> nil
        match?(%Decimal{}, assigns.users_useful_cost) -> assigns.users_useful_cost
        true -> useful_cost(users)
      end

    services_useful = useful_cost(if(single?, do: subject, else: services))

    thinking =
      if single?,
        do: subject.think_cost_usd,
        else: add_money(users.think_cost_usd, services.think_cost_usd)

    errors =
      if single?,
        do: subject.error_cost_usd,
        else: add_money(users.error_cost_usd, services.error_cost_usd)

    router = overall.router_decision_cost_usd

    segments =
      [
        %{
          key: "users",
          label: gettext("Users · useful"),
          amount: users_useful,
          color: "bg-primary"
        },
        %{
          key: "services",
          label: gettext("Services · useful"),
          amount: services_useful,
          color: "bg-warning"
        },
        %{key: "thinking", label: gettext("Thinking tax"), amount: thinking, color: "bg-accent"},
        %{key: "errors", label: gettext("Error waste"), amount: errors, color: "bg-error"},
        %{
          key: "router",
          label: gettext("Router overhead"),
          amount: router,
          color: "bg-base-content/40"
        }
      ]
      |> Enum.reject(&is_nil(&1.amount))
      |> with_percentages()

    total = Enum.reduce(segments, Decimal.new(0), &Decimal.add(&1.amount, &2))
    has_data? = segments != [] and Decimal.compare(total, Decimal.new(0)) == :gt

    cache = if single?, do: subject, else: overall

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:segments, segments)
      |> assign(:has_data?, has_data?)
      |> assign(:single?, single?)
      |> assign(:cache, cache)

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-3">
        <div class="flex items-center justify-between flex-wrap gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-banknotes" class="w-5 h-5 text-base-content/60" />
            {@title || gettext("Where every dollar went")}
          </h2>
          <span class="text-xs text-base-content/50 tabular-nums" id={"#{@id}-total"}>
            {Stats.money(@total)}
          </span>
        </div>

        <div
          :if={not @has_data?}
          class="h-20 flex items-center justify-center text-base-content/40 text-sm"
        >
          {gettext("No spend in this period.")}
        </div>

        <div :if={@has_data?} class="space-y-3">
          <div
            class="flex h-3 w-full overflow-hidden rounded-full bg-base-300/30"
            id={"#{@id}-bar"}
            role="img"
            aria-label={gettext("Spend anatomy")}
          >
            <div
              :for={segment <- @segments}
              class={["h-full transition-colors", segment.color]}
              style={"width: #{segment.pct}%"}
              id={"#{@id}-segment-#{segment.key}"}
              title={"#{segment.label}: #{Stats.money(segment.amount)} (#{segment.pct}%)"}
            >
            </div>
          </div>

          <ul class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-1.5" id={"#{@id}-legend"}>
            <li
              :for={segment <- @segments}
              class="flex items-center justify-between gap-2 text-xs"
              id={"#{@id}-legend-#{segment.key}"}
            >
              <span class="flex items-center gap-1.5 min-w-0">
                <span class={["w-2 h-2 rounded-sm shrink-0", segment.color]} />
                <span class="text-base-content/60 truncate">{segment.label}</span>
              </span>
              <span class="tabular-nums text-base-content/80 shrink-0">
                {Stats.money(segment.amount)}
                <span class="text-base-content/40">· {segment.pct}%</span>
              </span>
            </li>
          </ul>
        </div>

        <div
          class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-2 pt-2 border-t border-base-300/60"
          id={"#{@id}-pills"}
        >
          <.anatomy_pill
            id={"#{@id}-pill-cache"}
            icon="hero-circle-stack"
            label={gettext("Prompt cache")}
            value={
              gettext("%{read} read · %{write} write",
                read: Stats.format_compact(@cache.cache_read_tokens),
                write: Stats.format_compact(@cache.cache_creation_tokens)
              )
            }
          />
          <.anatomy_pill
            id={"#{@id}-pill-local"}
            icon="hero-bolt"
            label={gettext("Local cache · $0")}
            value={gettext("%{hits} hits", hits: Stats.format_number(@cache.local_cache_hits))}
          />
          <.anatomy_pill
            id={"#{@id}-pill-saved"}
            icon="hero-scissors"
            label={gettext("Prompt tokens saved")}
            value={Stats.format_compact(@cache.prompt_tokens_saved_est)}
          />
          <.anatomy_pill
            id={"#{@id}-pill-topups"}
            icon="hero-arrow-up-circle"
            label={gettext("Top-ups vs quota")}
            value={
              gettext("%{cost} · %{count} req",
                cost: Stats.money(@cache.topup_cost_usd),
                count: Stats.format_number(@cache.topup_requests)
              )
            }
          />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp anatomy_pill(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300/70 bg-base-200/40 px-3 py-2">
      <div class="flex items-center gap-1.5 text-[10px] uppercase tracking-wide text-base-content/50">
        <.icon name={@icon} class="w-3.5 h-3.5" />
        <span class="truncate">{@label}</span>
      </div>
      <p class="mt-1 text-xs font-medium tabular-nums text-base-content/80">{@value}</p>
    </div>
    """
  end

  ## Capacidades (request_type) --------------------------------------------

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :title, :string, default: nil

  def capability_bars(assigns) do
    rows = Enum.map(assigns.rows, &capability_row/1)
    max_cost = rows |> Enum.map(& &1.cost_float) |> Enum.max(fn -> 0.0 end)

    rows =
      Enum.map(rows, fn row ->
        width = bar_width(row, max_cost)
        user_width = if row.requests > 0, do: width * row.user_share / 100, else: 0.0

        Map.merge(row, %{
          width: round2(width),
          user_width: round2(user_width),
          service_width: round2(width - user_width)
        })
      end)

    assigns = assigns |> assign(:rows, rows) |> assign(:has_data?, rows != [])

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-3">
        <h2 class="card-title text-base">
          <.icon name="hero-squares-2x2" class="w-5 h-5 text-base-content/60" />
          {@title || gettext("Cost by capability")}
        </h2>

        <div
          :if={not @has_data?}
          class="h-32 flex items-center justify-center text-base-content/40 text-sm"
        >
          {gettext("No data in this period.")}
        </div>

        <div :if={@has_data?} class="space-y-3" id={"#{@id}-list"}>
          <div :for={row <- @rows} class="space-y-1" id={"#{@id}-#{row.slug}"}>
            <div class="flex items-baseline justify-between gap-2">
              <span class="text-xs font-medium text-base-content/70 truncate">{row.label}</span>
              <span class="text-[10px] tabular-nums text-base-content/50 shrink-0">
                {Stats.money(row.cost_usd)} · {Stats.format_number(row.requests)} req
              </span>
            </div>

            <svg
              viewBox="0 0 100 6"
              class="w-full h-2"
              preserveAspectRatio="none"
              role="img"
              aria-label={row.label}
            >
              <rect x="0" y="0" width="100" height="6" rx="1" class="fill-base-300/40" />
              <rect
                x="0"
                y="0"
                width={row.user_width}
                height="6"
                rx="1"
                class="fill-primary"
              >
                <title>{row.tooltip}</title>
              </rect>
              <rect
                :if={row.service_width > 0}
                x={row.user_width}
                y="0"
                width={row.service_width}
                height="6"
                rx="1"
                class="fill-warning"
              >
                <title>{row.tooltip}</title>
              </rect>
            </svg>

            <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5 text-[10px] text-base-content/50 tabular-nums">
              <span>{gettext("$/req")} {Stats.cost_per_request(row.cost_usd, row.requests)}</span>
              <span>{Stats.effective_cost_per_1m(
                row.cost_usd,
                row.prompt_tokens,
                row.completion_tokens
              )}/1M tok</span>
              <span>
                {gettext("users %{users}% · services %{services}%",
                  users: row.user_share,
                  services: round2(100 - row.user_share)
                )}
              </span>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 pt-2 border-t border-base-300/60">
            <div class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-sm bg-primary" />
              <span class="text-[10px] text-base-content/60">{gettext("Users")}</span>
            </div>
            <div class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-sm bg-warning" />
              <span class="text-[10px] text-base-content/60">{gettext("Services")}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## Dispersión de eficiencia ----------------------------------------------

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :y_metric, :string, default: "cpr"
  attr :toggle_event, :string, default: nil
  attr :period, :any, required: true
  attr :title, :string, default: nil
  # Requests facturables mínimas para entrar al cuadrante de eficientes: un
  # sujeto con una sola llamada no se corona por $/req.
  attr :min_volume, :integer, default: 10
  # Pares {valor, etiqueta} del toggle del eje Y. `nil` = sujetos
  # ($/req · caché); el mapa de modelos/proveedores pasa ($/req · razonamiento).
  attr :y_options, :list, default: nil
  # Toggle Models | Providers (solo en el mapa de entidades).
  attr :entity_toggle_event, :string, default: nil
  attr :entity_value, :string, default: nil

  def efficiency_scatter(assigns) do
    y_metric = if assigns.y_metric in ~w(cpr cache think), do: assigns.y_metric, else: "cpr"

    # Sujetos 100% servidos por caché local: no tienen `$/req` que comparar
    # (costaron $0), pero tampoco pueden desaparecer del mapa — se muestran
    # aparte como lo que son, tráfico no facturable.
    zero_billable =
      assigns.rows
      |> Enum.filter(fn row ->
        Map.get(row, :subject_type) in ["user", "service"] and
          (Map.get(row, :billable_requests) || row.request_count) == 0 and row.request_count > 0
      end)
      |> Enum.sort_by(& &1.request_count, :desc)
      |> Enum.map(fn row ->
        %{
          label: row.label,
          requests: row.request_count,
          href: subject_href(row, assigns.period)
        }
      end)

    points =
      assigns.rows
      |> Enum.map(&scatter_point(&1, y_metric, assigns.period))
      |> Enum.reject(&is_nil/1)

    groups = points |> Enum.group_by(& &1.kind) |> Enum.sort_by(fn {kind, _} -> kind end)
    groups_map = Map.new(groups)

    x_max = points |> Enum.map(& &1.x) |> Enum.max(fn -> 0 end)
    y_max = points |> Enum.map(& &1.y) |> Enum.max(fn -> 0.0 end)
    cost_max = points |> Enum.map(& &1.cost) |> Enum.max(fn -> 0.0 end)

    has_data? = points != [] and x_max > 0

    x_ceil = if x_max > 0, do: Stats.nice_ceiling(x_max), else: 10
    y_ceil = if y_metric == "cache", do: 100.0, else: axis_ceiling(y_max, "cpr")

    points =
      if has_data? do
        Enum.map(points, fn point ->
          radius = 3.0 + :math.sqrt(point.cost / max(cost_max, 0.000001)) * 12.0

          Map.merge(point, %{
            px: round2(@scatter_left + :math.sqrt(point.x / x_ceil) * plot_width()),
            py: round2(@scatter_top + (1.0 - point.y / y_ceil) * plot_height()),
            r: round2(radius)
          })
        end)
      else
        []
      end

    guides =
      groups
      |> Enum.flat_map(fn {kind, group} ->
        x_med = median(Enum.map(group, & &1.x))
        y_med = median(Enum.map(group, & &1.y))

        [
          %{
            kind: kind,
            x_med: x_med,
            y_med: y_med,
            px: round2(@scatter_left + :math.sqrt(x_med / x_ceil) * plot_width()),
            py: round2(@scatter_top + (1.0 - y_med / y_ceil) * plot_height())
          }
        ]
      end)

    # Cuadrante eficiente de cada grupo: alto volumen y bajo costo unitario
    # contra SU propia mediana, y con muestra suficiente para contar.
    efficient =
      guides
      |> Enum.map(fn guide ->
        group = Map.get(groups_map, guide.kind, [])

        rows =
          group
          |> Enum.filter(fn point ->
            point.billable >= assigns.min_volume and point.x >= guide.x_med and
              point.y <= guide.y_med
          end)
          |> Enum.sort_by(& &1.cost, :desc)
          |> Enum.take(5)
          |> Enum.map(fn point ->
            Map.put(
              point,
              :cpr_label,
              Stats.cost_per_request(Decimal.from_float(point.cost), point.billable)
            )
          end)

        {guide.kind, rows}
      end)
      |> Enum.reject(fn {_kind, rows} -> rows == [] end)

    assigns =
      assigns
      |> assign(:y_metric, y_metric)
      |> assign(:points, points)
      |> assign(:guides, if(has_data?, do: guides, else: []))
      |> assign(:efficient, efficient)
      |> assign(:zero_billable, zero_billable)
      |> assign(:kinds, Enum.map(groups, fn {kind, _} -> kind end))
      |> assign(:y_options, assigns.y_options || default_y_options())
      |> assign(:y_label, y_label(y_metric))
      |> assign(:has_data?, has_data?)
      |> assign(:x_ceil, x_ceil)
      |> assign(:y_ceil, y_ceil)
      |> assign(:y_ticks, scatter_ticks(y_ceil))
      |> assign(:x_ticks, scatter_ticks(x_ceil))
      |> assign(:geo, %{
        w: @scatter_w,
        h: @scatter_h,
        left: @scatter_left,
        right: @scatter_right,
        top: @scatter_top,
        bottom: @scatter_bottom
      })

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-2">
        <div class="flex items-center justify-between flex-wrap gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-chart-pie" class="w-5 h-5 text-base-content/60" />
            {@title || gettext("Efficiency map")}
          </h2>
          <div class="flex items-center gap-2 flex-wrap">
            <div :if={@entity_toggle_event} class="join" id={"#{@id}-entity-toggle"}>
              <button
                :for={
                  {value, label} <- [
                    {"models", gettext("Models")},
                    {"providers", gettext("Providers")}
                  ]
                }
                type="button"
                phx-click={@entity_toggle_event}
                phx-value-entity={value}
                class={[
                  "btn btn-xs join-item",
                  if(@entity_value == value, do: "btn-primary", else: "btn-ghost")
                ]}
              >
                {label}
              </button>
            </div>
            <div :if={@toggle_event} class="join" id={"#{@id}-metric-toggle"}>
              <button
                :for={{value, label} <- @y_options}
                type="button"
                phx-click={@toggle_event}
                phx-value-metric={value}
                class={[
                  "btn btn-xs join-item",
                  if(@y_metric == value, do: "btn-primary", else: "btn-ghost")
                ]}
              >
                {label}
              </button>
            </div>
          </div>
        </div>

        <p class="text-[10px] leading-snug text-base-content/40">
          {gettext(
            "X = billable requests · Y = %{y} · bubble size = cost · halo = has $0 local-cache traffic · lines = period median per group · click a bubble for the subject",
            y: @y_label
          )}
        </p>

        <div
          :if={not @has_data?}
          class="h-44 flex items-center justify-center text-base-content/40 text-sm"
        >
          {gettext("No data in this period.")}
        </div>

        <svg
          :if={@has_data?}
          viewBox="0 0 600 220"
          class="w-full"
          role="img"
          aria-label={gettext("Efficiency map")}
          id={"#{@id}-plot"}
        >
          <%!-- Cuadrante eficiente (alto volumen · bajo $/req) por grupo: el
               sombreado y las líneas usan la MEDIANA del propio grupo, así un
               servicio de embeddings no se compara contra un humano con
               Claude Code. --%>
          <g :if={@guides != []} id={"#{@id}-quadrant-guides"}>
            <rect
              :for={guide <- @guides}
              id={"#{@id}-quadrant-#{guide.kind}"}
              x={guide.px}
              y={guide.py}
              width={round2(@geo.w - @geo.right - guide.px)}
              height={round2(@geo.h - @geo.bottom - guide.py)}
              class={kind_fill_soft_class(guide.kind)}
            />
            <line
              :for={guide <- @guides}
              x1={guide.px}
              x2={guide.px}
              y1={@geo.top}
              y2={@geo.h - @geo.bottom}
              class={kind_stroke_class(guide.kind)}
              stroke-width="1"
              stroke-dasharray="4 4"
            />
            <line
              :for={guide <- @guides}
              x1={@geo.left}
              x2={@geo.w - @geo.right}
              y1={guide.py}
              y2={guide.py}
              class={kind_stroke_class(guide.kind)}
              stroke-width="1"
              stroke-dasharray="4 4"
            />
          </g>

          <line
            :for={tick <- @y_ticks}
            x1={@geo.left}
            x2={@geo.w - @geo.right}
            y1={scatter_y(tick, @y_ceil)}
            y2={scatter_y(tick, @y_ceil)}
            class="stroke-base-300/60"
            stroke-width="1"
            stroke-dasharray="3 4"
          />
          <line
            :for={tick <- @x_ticks}
            x1={scatter_x(tick, @x_ceil)}
            x2={scatter_x(tick, @x_ceil)}
            y1={@geo.top}
            y2={@geo.h - @geo.bottom}
            class="stroke-base-300/40"
            stroke-width="1"
            stroke-dasharray="3 4"
          />

          <line
            x1={@geo.left}
            x2={@geo.left}
            y1={@geo.top}
            y2={@geo.h - @geo.bottom}
            class="stroke-base-300"
            stroke-width="1"
          />
          <line
            x1={@geo.left}
            x2={@geo.w - @geo.right}
            y1={@geo.h - @geo.bottom}
            y2={@geo.h - @geo.bottom}
            class="stroke-base-300"
            stroke-width="1"
          />

          <text
            :for={tick <- @y_ticks}
            x={@geo.left - 6}
            y={scatter_y(tick, @y_ceil) + 3}
            text-anchor="end"
            class="fill-base-content/50"
            font-size="9"
          >
            {format_scatter_axis(tick, @y_metric)}
          </text>
          <text
            :for={tick <- @x_ticks}
            x={scatter_x(tick, @x_ceil)}
            y={@geo.h - 8}
            text-anchor="middle"
            class="fill-base-content/50"
            font-size="9"
          >
            {Stats.format_compact(round(tick))}
          </text>

          <%= for point <- @points do %>
            <%= if point.href do %>
              <a href={point.href}>
                <circle
                  :if={point.local_cache_hits > 0}
                  cx={point.px}
                  cy={point.py}
                  r={point.r + 3}
                  class="fill-none stroke-base-content/25"
                  stroke-width="1"
                  stroke-dasharray="2 2"
                />
                <circle
                  cx={point.px}
                  cy={point.py}
                  r={point.r}
                  class={["stroke-base-100", kind_fill_class(point.kind)]}
                  stroke-width="1"
                >
                  <title>{point.tip}</title>
                </circle>
              </a>
            <% else %>
              <circle
                :if={point.local_cache_hits > 0}
                cx={point.px}
                cy={point.py}
                r={point.r + 3}
                class="fill-none stroke-base-content/25"
                stroke-width="1"
                stroke-dasharray="2 2"
              />
              <circle
                cx={point.px}
                cy={point.py}
                r={point.r}
                class={kind_fill_class(point.kind)}
                stroke-width="1"
              >
                <title>{point.tip}</title>
              </circle>
            <% end %>
          <% end %>
        </svg>

        <div class="flex flex-wrap items-center gap-x-4 gap-y-1 mt-1" id={"#{@id}-legend"}>
          <div :for={kind <- @kinds} class="flex items-center gap-1.5">
            <span class={["w-2 h-2 rounded-full", kind_dot_class(kind)]} />
            <span class="text-[10px] text-base-content/60">{kind_label(kind)}</span>
          </div>
          <div class="flex items-center gap-1.5">
            <span class="w-3 h-3 rounded-sm bg-primary/5 border border-primary/40 border-dashed" />
            <span class="text-[10px] text-base-content/60">{gettext("Efficient quadrant")}</span>
          </div>
          <div
            :if={Enum.any?(@kinds, &(&1 in ["user", "service"]))}
            class="flex items-center gap-1.5"
          >
            <span class="w-3.5 h-3.5 rounded-full border border-dashed border-base-content/40" />
            <span class="text-[10px] text-base-content/60">{gettext("Has $0 local-cache traffic")}</span>
          </div>
        </div>

        <%!-- No facturable, pero tampoco invisible: los sujetos servidos al
             100% por caché local costaron $0 y no tienen `$/req` que comparar,
             así que viven en su propia tira con sus requests ahorradas. --%>
        <div
          :if={@zero_billable != []}
          id={"#{@id}-cache-only"}
          class="pt-2 border-t border-base-300/60"
        >
          <p class="text-[10px] uppercase tracking-wide text-base-content/40">
            {gettext("Non-billable · 100% local cache ($0)")}
          </p>
          <ul class="flex flex-wrap gap-x-3 gap-y-1">
            <li
              :for={{row, index} <- Enum.with_index(@zero_billable)}
              id={"#{@id}-cache-only-#{index}"}
            >
              <.link :if={row.href} navigate={row.href} class="text-xs link link-hover">
                {row.label}
                <span class="text-base-content/50 tabular-nums">
                  {gettext("%{count} req at $0", count: Stats.format_number(row.requests))}
                </span>
              </.link>
              <span :if={is_nil(row.href)} class="text-xs">
                {row.label}
                <span class="text-base-content/50 tabular-nums">
                  {gettext("%{count} req at $0", count: Stats.format_number(row.requests))}
                </span>
              </span>
            </li>
          </ul>
        </div>

        <%!-- Los eficientes, en UN solo lugar: alto volumen + bajo $/req contra
             la mediana de su propio grupo, con muestra mínima facturable. --%>
        <div
          :if={@efficient != []}
          id={"#{@id}-efficient"}
          class="pt-2 border-t border-base-300/60 space-y-2"
        >
          <div :for={{kind, rows} <- @efficient}>
            <p class="text-[10px] uppercase tracking-wide text-base-content/40">
              {efficient_label(kind)}
              <span class="normal-case tracking-normal">
                · {gettext("high volume · low $/req")}
              </span>
            </p>
            <ul class="flex flex-wrap gap-x-3 gap-y-1">
              <li
                :for={{point, index} <- Enum.with_index(rows)}
                id={"#{@id}-efficient-#{kind}-#{index}"}
              >
                <.link
                  :if={point.href}
                  navigate={point.href}
                  class="text-xs link link-hover"
                >
                  {point.label}
                  <span class="text-base-content/50 tabular-nums">{point.cpr_label}</span>
                </.link>
                <span :if={is_nil(point.href)} class="text-xs">
                  {point.label}
                  <span class="text-base-content/50 tabular-nums">{point.cpr_label}</span>
                </span>
              </li>
            </ul>
          </div>
        </div>

        <p
          :if={@has_data? and @efficient == []}
          id={"#{@id}-efficient-empty"}
          class="text-[10px] text-base-content/40"
        >
          {gettext("No subject in the efficient quadrant yet (minimum %{count} billable requests).",
            count: @min_volume
          )}
        </p>
      </div>
    </div>
    """
  end

  ## Helpers ---------------------------------------------------------------

  # `%{overall:, users:, services:}` de `Rollup.finops_overview/1`; un bloque
  # suelto (finops de UN servicio) se acepta tal cual.
  defp normalize_overview(nil), do: empty_overview()

  defp normalize_overview(%{overall: overall} = overview) do
    %{
      overall: overall,
      users: Map.get(overview, :users) || zero_block(),
      services: Map.get(overview, :services) || zero_block()
    }
  end

  defp normalize_overview(block) when is_map(block),
    do: %{overall: block, users: zero_block(), services: zero_block()}

  defp empty_overview, do: %{overall: zero_block(), users: zero_block(), services: zero_block()}

  defp zero_block do
    %{
      requests: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      error_requests: 0,
      error_cost_usd: Decimal.new(0),
      think_requests: 0,
      think_cost_usd: Decimal.new(0),
      local_cache_hits: 0,
      router_decision_cost_usd: Decimal.new(0),
      prompt_tokens_saved_est: 0,
      topup_requests: 0,
      topup_cost_usd: Decimal.new(0),
      active_subjects: 0
    }
  end

  defp useful_cost(block) do
    block.cost_usd
    |> Decimal.sub(block.think_cost_usd || Decimal.new(0))
    |> Decimal.sub(block.error_cost_usd || Decimal.new(0))
    |> max_money()
  end

  defp max_money(%Decimal{} = value) do
    if Decimal.compare(value, Decimal.new(0)) == :lt, do: Decimal.new(0), else: value
  end

  defp add_money(a, b), do: Decimal.add(a || Decimal.new(0), b || Decimal.new(0))

  defp with_percentages([]), do: []

  defp with_percentages(segments) do
    total = Enum.reduce(segments, Decimal.new(0), &Decimal.add(&1.amount, &2))

    Enum.map(segments, fn segment ->
      pct =
        if Decimal.compare(total, Decimal.new(0)) == :gt do
          segment.amount
          |> Decimal.div(total)
          |> Decimal.mult(Decimal.new(100))
          |> Decimal.round(1, :half_up)
          |> Decimal.to_float()
        else
          0.0
        end

      Map.put(segment, :pct, pct)
    end)
  end

  defp build_buckets([]), do: []

  defp build_buckets(series) do
    series
    |> Enum.group_by(&sort_key(&1.date))
    |> Enum.sort_by(fn {key, _rows} -> key end)
    |> Enum.map(fn {_key, rows} ->
      users = Enum.filter(rows, &(&1.subject_type == "user"))
      services = Enum.filter(rows, &(&1.subject_type == "service"))

      %{
        label: bucket_label(hd(rows).date),
        users: aggregate(users),
        services: aggregate(services)
      }
    end)
  end

  defp aggregate(rows) do
    %{
      requests: Enum.reduce(rows, 0, &(&1.request_count + &2)),
      cost: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.cost_usd, &2))
    }
  end

  defp total_agg(bucket) do
    %{
      requests: bucket.users.requests + bucket.services.requests,
      cost: Decimal.add(bucket.users.cost, bucket.services.cost)
    }
  end

  defp sort_key(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp sort_key(%DateTime{} = dt), do: dt
  defp sort_key(other), do: other

  defp bucket_label(%Date{} = date), do: Calendar.strftime(date, "%d %b")
  defp bucket_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp bucket_label(_), do: ""

  defp metric_value(agg, "requests"), do: agg.requests * 1.0
  defp metric_value(agg, "cost"), do: Decimal.to_float(agg.cost)

  defp metric_value(agg, "cpr") do
    if agg.requests > 0, do: Decimal.to_float(agg.cost) / agg.requests, else: 0.0
  end

  # Escala del eje Y: entero "nice" para conteos, flotante "nice" para dinero
  # (los costos por debajo de $1 se redondeaban a 10 con `nice_ceiling/1`).
  defp axis_ceiling(max_value, "requests"),
    do: max(Stats.nice_ceiling(parse_zero(max_value)), 1)

  defp axis_ceiling(max, _metric), do: nice_float_ceiling(max)

  defp parse_zero(value) when is_number(value), do: value
  defp parse_zero(_), do: 0

  defp nice_float_ceiling(value) when value <= 0, do: 1.0

  defp nice_float_ceiling(value) do
    exp = value |> :math.log10() |> Float.floor()
    base = :math.pow(10, exp)
    fraction = value / base

    nice_fraction =
      cond do
        fraction <= 1 -> 1.0
        fraction <= 2 -> 2.0
        fraction <= 5 -> 5.0
        true -> 10.0
      end

    nice_fraction * base
  end

  defp axis_ticks(scale_max) do
    for i <- 1..3, do: scale_max * i / 3
  end

  defp x_at(_index, count) when count <= 1, do: @chart_w / 2

  defp x_at(index, count) do
    @pad_x + index * (@chart_w - 2 * @pad_x) / (count - 1)
  end

  defp y_pos(value, scale_max) do
    plot_height = @chart_h - @pad_top - @pad_bottom
    ratio = if scale_max > 0, do: value / scale_max, else: 0.0
    round2(@pad_top + (1.0 - ratio) * plot_height)
  end

  defp tick_bottom_pct(value, scale_max) do
    round2((@chart_h - y_pos(value, scale_max)) / @chart_h * 100)
  end

  defp layout_points(rows, scale_max) do
    count = length(rows)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      %{
        label: row.label,
        x: round2(x_at(index, count)),
        raw_primary: row.primary,
        raw_secondary: row.secondary,
        primary: y_pos(row.primary, scale_max),
        secondary: if(row.secondary == nil, do: nil, else: y_pos(row.secondary, scale_max))
      }
    end)
  end

  defp line_path(points, key) do
    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {point, index} ->
      prefix = if index == 0, do: "M", else: "L"
      "#{prefix}#{point.x},#{point[key]}"
    end)
  end

  defp area_path([], _key), do: ""

  defp area_path(points, key) do
    baseline = @chart_h - @pad_bottom
    first = hd(points)
    last = List.last(points)

    line_path(points, key) <>
      " L#{last.x},#{baseline} L#{first.x},#{baseline} Z"
  end

  defp hover_bands(points, _count, metric, primary_label, secondary_label, _single?) do
    xs = Enum.map(points, & &1.x)
    total = length(xs)

    xs
    |> Enum.with_index()
    |> Enum.map(fn {x, index} ->
      # Banda de hover = mitad de la distancia a los vecinos: sin solapes y
      # cubriendo todo el ancho (los extremos llegan al borde).
      left = if index == 0, do: 0.0, else: (Enum.at(xs, index - 1) + x) / 2

      right =
        if index == total - 1, do: @chart_w * 1.0, else: (x + Enum.at(xs, index + 1)) / 2

      point = Enum.at(points, index)

      %{
        cx: x,
        x: round2(left),
        width: round2(right - left),
        tip: band_tip(point, metric, primary_label, secondary_label)
      }
    end)
  end

  defp band_tip(point, metric, primary_label, secondary_label) do
    secondary =
      if point.raw_secondary == nil,
        do: [],
        else: ["#{secondary_label} #{format_value(point.raw_secondary, metric)}"]

    Enum.join(
      ["#{point.label}", "#{primary_label} #{format_value(point.raw_primary, metric)}"] ++
        secondary,
      " · "
    )
  end

  defp format_value(value, metric) when metric == "cpr",
    do: Stats.money(Decimal.from_float(value * 1.0))

  defp format_value(value, "requests"), do: Stats.format_number(round(value))

  defp format_value(value, _metric),
    do: Stats.money(Decimal.from_float(value * 1.0))

  defp format_axis(value, "requests"), do: Stats.format_number(round(value))
  defp format_axis(value, _metric), do: Stats.money(Decimal.from_float(value * 1.0))

  defp x_labels(points) do
    count = length(points)
    step = if count > 8, do: div(count, 6) + 1, else: 1

    points
    |> Enum.with_index()
    |> Enum.filter(fn {_point, index} ->
      rem(index, step) == 0 or index == count - 1
    end)
    |> Enum.map(fn {point, _index} ->
      %{text: point.label, left: round2(point.x / @chart_w * 100)}
    end)
  end

  defp capability_row(row) do
    cost_float = Decimal.to_float(row.cost_usd)

    %{
      slug: slug(row.request_type),
      label: capability_label(row.request_type),
      request_type: row.request_type,
      requests: row.request_count,
      cost_usd: row.cost_usd,
      cost_float: cost_float,
      prompt_tokens: row.prompt_tokens,
      completion_tokens: row.completion_tokens,
      user_share:
        if(row.request_count > 0,
          do: round2(row.user_requests / row.request_count * 100),
          else: 0.0
        ),
      tooltip:
        gettext("%{type}: %{cost} · %{requests} req",
          type: capability_label(row.request_type),
          cost: Stats.money(row.cost_usd),
          requests: Stats.format_number(row.request_count)
        )
    }
  end

  defp bar_width(_row, max_cost) when max_cost <= 0, do: 0.0

  defp bar_width(%{cost_float: cost, requests: requests}, max_cost) do
    width = cost / max_cost * 100

    if width <= 0 and requests > 0, do: 1.0, else: max(width, 0.0)
  end

  defp capability_label(type) when is_binary(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp capability_label(_), do: gettext("Unknown")

  defp slug(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slug(_), do: "unknown"

  defp scatter_point(row, y_metric, period) do
    requests = Map.get(row, :request_count) || Map.get(row, :requests) || 0
    billable = Map.get(row, :billable_requests) || requests
    cost = Decimal.to_float(row.cost_usd)
    think = Decimal.to_float(Map.get(row, :think_cost_usd) || Decimal.new(0))
    kind = Map.get(row, :subject_type) || Map.get(row, :kind) || "model"

    y =
      cond do
        y_metric == "think" and cost > 0 ->
          think / cost * 100

        y_metric == "think" ->
          nil

        y_metric == "cache" and row.prompt_tokens > 0 ->
          row.cache_read_tokens / row.prompt_tokens * 100

        y_metric == "cache" ->
          nil

        # El eje del dinero se mide sobre requests FACTURABLES: los hits de
        # caché local ($0) no compran eficiencia. Un sujeto sin requests
        # facturables no tiene $/req que comparar y sale del mapa.
        billable > 0 ->
          cost / billable

        true ->
          nil
      end

    if is_nil(y) do
      nil
    else
      %{
        kind: kind,
        label: row.label,
        # X = requests FACTURABLES: la misma base que el `$/req` del eje Y. El
        # total y el caché local viajan en el tooltip y en el halo.
        x: billable,
        y: y,
        cost: cost,
        billable: billable,
        requests: requests,
        think_cost: think,
        local_cache_hits: Map.get(row, :local_cache_hits, 0),
        href: subject_href(row, period),
        tip:
          Enum.join(
            [
              row.label,
              gettext("%{count} billable", count: Stats.format_number(billable)),
              gettext("%{count} total req", count: Stats.format_number(requests)),
              gettext("%{count} local cache ($0)",
                count: Stats.format_number(Map.get(row, :local_cache_hits, 0))
              ),
              gettext("$/req %{value}", value: Stats.cost_per_request(row.cost_usd, billable)),
              gettext("cost %{value}", value: Stats.money(row.cost_usd)),
              gettext("reasoning %{value}",
                value: Stats.money(Map.get(row, :think_cost_usd) || Decimal.new(0))
              )
            ],
            " · "
          )
      }
    end
  end

  defp subject_href(%{subject_type: "user", subject_id: id}, period) when is_binary(id),
    do: "/stats/users/#{id}?period=#{period}"

  defp subject_href(%{subject_type: "service", subject_id: id}, period) when is_binary(id),
    do: "/stats/services/#{id}?period=#{period}"

  defp subject_href(%{kind: "model", entity_id: id}, period) when is_binary(id),
    do: "/stats/models/#{id}?period=#{period}"

  defp subject_href(%{kind: "provider", entity_id: id}, period) when is_binary(id),
    do: "/stats/providers/#{id}?period=#{period}"

  defp subject_href(_row, _period), do: nil

  defp scatter_ticks(max_value) do
    for i <- 0..3, do: max_value * i / 3
  end

  # Mediana para las líneas de corte del cuadrante: aguanta un outlier caro
  # que un promedio dejaría arrastrando la línea.
  defp median([]), do: 0.0

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    mid = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, mid) * 1.0
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  # --- Etiquetas del mapa (sujetos vs entidades) ---------------------------

  defp default_y_options do
    [
      {"cpr", gettext("$/req")},
      {"cache", gettext("Cache hit %")}
    ]
  end

  defp y_label("think"), do: gettext("reasoning % of spend")
  defp y_label("cache"), do: gettext("cache hit %")
  defp y_label(_), do: gettext("$ per billable request")

  defp kind_label("model"), do: gettext("Models")
  defp kind_label("provider"), do: gettext("Providers")
  defp kind_label("service"), do: gettext("Services")
  defp kind_label(_), do: gettext("Users")

  defp efficient_label("model"), do: gettext("Efficient models")
  defp efficient_label("provider"), do: gettext("Efficient providers")
  defp efficient_label("service"), do: gettext("Efficient services")
  defp efficient_label(_), do: gettext("Efficient users")

  defp kind_dot_class("service"), do: "bg-warning/70"
  defp kind_dot_class("provider"), do: "bg-warning/70"
  defp kind_dot_class(_), do: "bg-primary/70"

  defp kind_fill_class("service"), do: "fill-warning/70 hover:fill-warning"
  defp kind_fill_class("provider"), do: "fill-warning/70 hover:fill-warning"
  defp kind_fill_class(_), do: "fill-primary/70 hover:fill-primary"

  defp kind_stroke_class("service"), do: "stroke-warning/50"
  defp kind_stroke_class("provider"), do: "stroke-warning/50"
  defp kind_stroke_class(_), do: "stroke-primary/40"

  defp kind_fill_soft_class("service"), do: "fill-warning/5"
  defp kind_fill_soft_class("provider"), do: "fill-warning/5"
  defp kind_fill_soft_class(_), do: "fill-primary/5"

  defp plot_width, do: @scatter_w - @scatter_left - @scatter_right
  defp plot_height, do: @scatter_h - @scatter_top - @scatter_bottom

  defp scatter_x(value, x_ceil) do
    ratio = if x_ceil > 0, do: :math.sqrt(max(value, 0.0) / x_ceil), else: 0.0
    round2(@scatter_left + ratio * plot_width())
  end

  defp scatter_y(value, y_ceil) do
    ratio = if y_ceil > 0, do: value / y_ceil, else: 0.0
    round2(@scatter_top + (1.0 - ratio) * plot_height())
  end

  defp format_scatter_axis(value, "cache"), do: "#{round(value)}%"

  defp format_scatter_axis(value, _metric),
    do: Stats.money(Decimal.from_float(value * 1.0))

  defp round2(value) when is_float(value), do: Float.round(value, 2)
  defp round2(value), do: value
end
