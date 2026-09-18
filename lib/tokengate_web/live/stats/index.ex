defmodule TokengateWeb.StatsLive.Index do
  @moduledoc """
  Sección index de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.DayHourChart

  import TokengateWeb.KpiHelpers, only: [kpi_cards: 1]

  attr :metrics, :any, required: true
  attr :peak_concurrency, :any, required: true
  attr :busiest_hours, :any, required: true
  attr :busiest_minutes, :any, required: true
  attr :hour_usage_by_provider, :any, required: true
  attr :model_provider_stacked, :any, required: true
  attr :period, :any, required: true
  attr :timezone, :any, required: true
  attr :budget_reset_hours, :any, required: true
  attr :budget_reset_minutes, :any, required: true
  attr :budget_reset_at, :any, required: true
  attr :current_user, :any, required: true

  def index(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- El card del tope diario global ya NO vive acá: mide el kill-switch
           (día UTC) y su casa es En vivo (`live-org-budget`). Con el período
           "hoy" era el mismo card con la misma query repetido en las dos
           pestañas; con ventanas más largas duplicaba el costo del KPI de
           costo, que ya mide el gasto del período. --%>

      <%!-- KPI cards — con período "Hoy" el costo mide el día UTC y declara
           cuánto falta para el reinicio del tope, igual que En vivo. --%>
      <.kpi_cards
        metrics={@metrics}
        deltas={@metrics[:deltas]}
        period={@period}
        reset_hours={@budget_reset_hours}
        reset_minutes={@budget_reset_minutes}
        reset_at={@budget_reset_at}
        timezone={@timezone}
      />

      <%!-- KPIs secundarios: concurrencia, horas y minutos pico --%>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <%= if @current_user && @current_user.global_role == "admin" do %>
          <div
            id="peak-concurrency"
            class="card bg-base-100 border border-base-300 shadow-sm"
          >
            <div class="card-body p-5">
              <div class="flex items-center justify-between">
                <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  {gettext("Peak concurrency")}
                </span>
                <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-primary/10">
                  <.icon name="hero-arrow-trending-up" class="w-5 h-5 text-primary" />
                </span>
              </div>
              <%= if @peak_concurrency && @peak_concurrency.max_concurrent > 0 do %>
                <p class="mt-2 text-2xl font-bold text-base-content">
                  {Stats.format_number(@peak_concurrency.max_concurrent)}
                </p>
                <p class="text-xs text-base-content/40 mt-1">
                  requests simultáneos · {format_bucket(
                    @peak_concurrency.at,
                    @timezone
                  )}
                </p>
              <% else %>
                <p class="text-sm text-base-content/40 mt-2">
                  {gettext("No data")}
                </p>
              <% end %>
            </div>
          </div>
        <% end %>

        <div id="busiest-hours" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <div class="flex items-center justify-between">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                {gettext("Peak hours")}
              </span>
              <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-warning/10">
                <.icon name="hero-fire" class="w-5 h-5 text-warning" />
              </span>
            </div>
            <%= if Stats.has_data?(@busiest_hours) do %>
              <ul class="mt-2 space-y-1">
                <li
                  :for={{row, idx} <- Enum.with_index(@busiest_hours, 1)}
                  id={"busiest-hour-#{idx}"}
                  class="flex items-center justify-between text-sm"
                >
                  <span class="text-base-content/70">
                    {idx}. {format_bucket(row.bucket, @timezone)}
                  </span>
                  <span class="font-mono">{Stats.format_number(row.request_count)}</span>
                </li>
              </ul>
            <% else %>
              <p class="text-sm text-base-content/40 mt-2">
                {gettext("No data")}
              </p>
            <% end %>
          </div>
        </div>

        <div id="busiest-minutes" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <div class="flex items-center justify-between">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                {gettext("Peak minutes")}
              </span>
              <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-accent/10">
                <.icon name="hero-bolt" class="w-5 h-5 text-accent" />
              </span>
            </div>
            <%= if Stats.has_data?(@busiest_minutes) do %>
              <ul class="mt-2 space-y-1">
                <li
                  :for={{row, idx} <- Enum.with_index(@busiest_minutes, 1)}
                  id={"busiest-minute-#{idx}"}
                  class="flex items-center justify-between text-sm"
                >
                  <span class="text-base-content/70">
                    {idx}. {format_bucket(row.bucket, @timezone)}
                  </span>
                  <span class="font-mono">{Stats.format_number(row.request_count)}</span>
                </li>
              </ul>
            <% else %>
              <p class="text-sm text-base-content/40 mt-2">
                {gettext("No data")}
              </p>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Patrones de uso del período: reparto por proveedor y por modelo —
           las DOS vistas se derivan en memoria del único agregado ya cargado
           (modelo × proveedor), sin queries extra. La tarjeta de perfil
           horario cierra la fila a lo ancho: es la misma que En vivo, con los
           datos del período, y sólo aparece cuando la ventana abarca más de un
           día (con "Hoy" ese día lo mide En vivo). --%>
      <% provider_rows = Stats.provider_legend(@model_provider_stacked) %>
      <% model_rows = Stats.model_rows(@model_provider_stacked) %>
      <% total_requests = Stats.model_provider_total(@model_provider_stacked) %>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" id="usage-patterns">
        <%!-- Card 1: Por proveedor — quién sirvió el período --%>
        <div
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="provider-breakdown"
        >
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-base">
                <.icon name="hero-server-stack" class="w-5 h-5 text-base-content/60" /> Por proveedor
              </h2>
              <span class="text-[10px] text-base-content/40 hidden sm:inline">
                reparto de {Stats.period_label(@period)} por requests
              </span>
            </div>

            <%= if provider_rows != [] do %>
              <ul class="mt-1" id="provider-breakdown-list">
                <Stats.ranked_row
                  :for={{row, rank} <- Enum.with_index(provider_rows, 1)}
                  rank={rank}
                  title={Stats.provider_label(row.provider_name)}
                  id={"provider-breakdown-row-#{rank}"}
                >
                  <:leading>
                    <Stats.provider_logo logo_url={row.provider_logo_url} size="md" />
                  </:leading>
                  <:metrics>
                    <Stats.metric_cell
                      label="Requests"
                      value={Stats.format_number(row.requests)}
                    />
                    <Stats.metric_cell
                      label="Reparto"
                      value={"#{Stats.share_pct(row.requests, total_requests)}%"}
                    />
                    <%= if Decimal.compare(row.cost_usd, Decimal.new(0)) == :gt do %>
                      <Stats.metric_cell
                        label="Costo"
                        value={"$" <> Stats.format_decimal(row.cost_usd)}
                        class="text-warning"
                      />
                    <% end %>
                  </:metrics>
                </Stats.ranked_row>
              </ul>
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                {gettext("No data in this period.")}
              </p>
            <% end %>
          </div>
        </div>

        <%!-- Card 2: Por modelo — qué se consumió, con su costo y en cuántos
             proveedores se sirvió --%>
        <div
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="model-breakdown"
        >
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-base">
                <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" /> Por modelo
              </h2>
              <span class="text-[10px] text-base-content/40 hidden sm:inline">
                top {length(model_rows)} por requests
              </span>
            </div>

            <%= if model_rows != [] do %>
              <ul class="mt-1" id="model-breakdown-list">
                <Stats.ranked_row
                  :for={{row, rank} <- Enum.with_index(model_rows, 1)}
                  rank={rank}
                  title={row.model_name}
                  id={"model-breakdown-row-#{rank}"}
                >
                  <:metrics>
                    <Stats.metric_cell
                      label="Requests"
                      value={Stats.format_number(row.requests)}
                    />
                    <Stats.metric_cell
                      label="Reparto"
                      value={"#{Stats.share_pct(row.requests, total_requests)}%"}
                    />
                    <Stats.metric_cell
                      label="Proveedores"
                      value={Stats.format_number(row.provider_count)}
                    />
                    <%= if Decimal.compare(row.cost_usd, Decimal.new(0)) == :gt do %>
                      <Stats.metric_cell
                        label="Costo"
                        value={"$" <> Stats.format_decimal(row.cost_usd)}
                        class="text-warning"
                      />
                    <% end %>
                  </:metrics>
                </Stats.ranked_row>
              </ul>
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                {gettext("No data in this period.")}
              </p>
            <% end %>
          </div>
        </div>

        <%!-- Perfil horario: la MISMA tarjeta que "Hoy por hora · por
             proveedor" de En vivo (stats/day_hour_chart.ex) — barras apiladas
             por proveedor, misma escala √, misma leyenda — aquí dibujada
             sobre la ventana del Resumen y sin liveness: los datos llegan con
             la carga del período, no de un push.

             Con ventanas de más de un día es el perfil del período en la hora
             local del usuario. Con "Hoy" es el día UTC en curso — la ventana
             de los KPI y del tope — con la hora actual marcada y las que aún
             no llegan atenuadas, para que el Resumen y En vivo lean el mismo
             día: las horas que ya pasaron son las que traen tráfico. --%>
        <% today? = @period == "today" %>
        <DayHourChart.day_hour_chart
          id="hour-distribution"
          class="lg:col-span-2"
          rows={@hour_usage_by_provider}
          title={gettext("Daily usage by hour")}
          hint={
            if today?,
              do:
                gettext(
                  "stacked bars · 1 bar = 1 hour of the UTC day · color = provider · current hour marked"
                ),
              else:
                gettext(
                  "stacked bars · 1 bar = 1 hour of the day · color = provider · hour in your local time · period aggregate"
                )
          }
          hour_suffix={if today?, do: "UTC", else: "hora local"}
          empty_note={
            if today?,
              do: gettext("no traffic in the UTC day yet"),
              else: gettext("no data in the period")
          }
          now_hour={if today?, do: DateTime.utc_now().hour, else: nil}
        />
      </div>
    </div>
    """
  end
end
