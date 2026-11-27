defmodule TokengateWeb.StatsLive.Index do
  @moduledoc """
  Sección index de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.DailyStackedChart
  alias TokengateWeb.StatsLive.DayHourChart

  import TokengateWeb.KpiHelpers, only: [kpi_cards: 1]

  attr :metrics, :any, required: true
  attr :peak_concurrency, :any, required: true
  attr :daily_series, :any, default: []
  attr :top_agents, :any, default: []
  attr :top_consumers, :any, default: []
  attr :busiest_hours, :any, required: true
  attr :busiest_cost_hours, :any, default: []
  attr :busiest_minutes, :any, required: true
  attr :busiest_cost_minutes, :any, default: []
  attr :hour_usage_by_provider, :any, required: true
  attr :model_provider_stacked, :any, required: true
  attr :chart_metric, :string, default: "requests"
  attr :overview_metric, :string, default: "cost"
  attr :period, :any, required: true
  attr :timezone, :any, required: true
  attr :current_user, :any, required: true

  def index(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- El card del gasto del día UTC vive en En vivo (`live-org-budget`): mide
           el día calendario UTC, la ventana de los KPI con período "hoy".
           Repetirlo acá duplicaba la query con ventanas más largas. --%>

      <%!-- KPI cards — con período "Hoy" el costo mide el día UTC. --%>
      <.kpi_cards
        metrics={@metrics}
        deltas={@metrics[:deltas]}
        period={@period}
        timezone={@timezone}
      />

      <% admin? = @current_user && @current_user.global_role == "admin" %>
      <% cost_mode? = @overview_metric == "cost" %>

      <%!-- Tendencia diaria por proveedor en periodos multi-día (semana / 30d):
           muestra cuándo se disparó el gasto y con qué proveedor. --%>
      <DailyStackedChart.daily_stacked_chart
        :if={admin? and @period in ["week", "30d"] and @daily_series != []}
        id="overview-daily-chart"
        title={gettext("Daily trend by provider")}
        period={@period}
        series={@daily_series}
        labels={daily_series_labels(@daily_series)}
        show_logos={true}
        metric={@chart_metric}
        toggle_event="set_chart_metric"
      />

      <%!-- KPIs secundarios: concurrencia, horas y minutos pico --%>
      <% hours_rows =
        if(cost_mode? and @busiest_cost_hours != [], do: @busiest_cost_hours, else: @busiest_hours) %>
      <% minutes_rows =
        if(cost_mode? and @busiest_cost_minutes != [],
          do: @busiest_cost_minutes,
          else: @busiest_minutes
        ) %>
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
                  {gettext("concurrent requests · %{bucket}",
                    bucket: format_bucket(@peak_concurrency.at, @timezone)
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
            <%= if Stats.has_data?(hours_rows) do %>
              <ul class="mt-2 space-y-1">
                <li
                  :for={{row, idx} <- Enum.with_index(hours_rows, 1)}
                  id={"busiest-hour-#{idx}"}
                  class="flex items-center justify-between text-sm gap-2"
                >
                  <span class="text-base-content/70">
                    {idx}. {format_bucket(row.bucket, @timezone)}
                  </span>
                  <span class="font-mono tabular-nums text-xs">
                    <%= if cost_mode? and Map.has_key?(row, :cost_usd) do %>
                      <span class="text-warning font-semibold">${Stats.format_decimal(row.cost_usd)}</span>
                      <span class="text-base-content/40">· {Stats.format_number(row.request_count)} req</span>
                    <% else %>
                      {Stats.format_number(row.request_count)}
                    <% end %>
                  </span>
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
            <%= if Stats.has_data?(minutes_rows) do %>
              <ul class="mt-2 space-y-1">
                <li
                  :for={{row, idx} <- Enum.with_index(minutes_rows, 1)}
                  id={"busiest-minute-#{idx}"}
                  class="flex items-center justify-between text-sm gap-2"
                >
                  <span class="text-base-content/70">
                    {idx}. {format_bucket(row.bucket, @timezone)}
                  </span>
                  <span class="font-mono tabular-nums text-xs">
                    <%= if cost_mode? and Map.has_key?(row, :cost_usd) do %>
                      <span class="text-warning font-semibold">${Stats.format_decimal(row.cost_usd)}</span>
                      <span class="text-base-content/40">· {Stats.format_number(row.request_count)} req</span>
                    <% else %>
                      {Stats.format_number(row.request_count)}
                    <% end %>
                  </span>
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
      <% sort_atom = if cost_mode?, do: :cost, else: :requests %>
      <% provider_rows = Stats.provider_legend(@model_provider_stacked, sort_atom) %>
      <% model_rows = Stats.model_rows(@model_provider_stacked, sort_atom) |> Enum.take(10) %>
      <% total_requests = Stats.model_provider_total(@model_provider_stacked) %>
      <% total_cost = Stats.model_provider_total_cost(@model_provider_stacked) %>
      <div class="flex items-center justify-between flex-wrap gap-2">
        <h2 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
          {gettext("Spend & usage attribution")}
        </h2>
        <div class="join" id="overview-metric-toggle">
          <button
            type="button"
            phx-click="set_overview_metric"
            phx-value-metric="cost"
            class={["btn btn-xs join-item", if(cost_mode?, do: "btn-primary", else: "btn-ghost")]}
          >
            {gettext("By cost")}
          </button>
          <button
            type="button"
            phx-click="set_overview_metric"
            phx-value-metric="requests"
            class={["btn btn-xs join-item", if(!cost_mode?, do: "btn-primary", else: "btn-ghost")]}
          >
            {gettext("By requests")}
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" id="usage-patterns">
        <%!-- Card 1: Por proveedor — quién sirvió el período --%>
        <div
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="provider-breakdown"
        >
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-base">
                <.icon name="hero-server-stack" class="w-5 h-5 text-base-content/60" />
                {gettext("By provider")}
              </h2>
              <span class="text-[10px] text-base-content/40 hidden sm:inline">
                {if cost_mode?,
                  do: gettext("share of %{period} by cost", period: Stats.period_label(@period)),
                  else: gettext("share of %{period} by requests", period: Stats.period_label(@period))}
              </span>
            </div>

            <%= if provider_rows != [] do %>
              <ul class="mt-1" id="provider-breakdown-list">
                <Stats.ranked_row
                  :for={{row, rank} <- Enum.with_index(provider_rows, 1)}
                  rank={rank}
                  title={Stats.provider_label(row.provider_name)}
                  href={
                    row.provider_stats_id &&
                      ~p"/stats/providers/#{row.provider_stats_id}?period=#{@period}"
                  }
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
                      label={gettext("Distribution")}
                      value={
                        if(cost_mode? and Decimal.compare(total_cost, Decimal.new(0)) == :gt,
                          do: "#{Stats.cost_share_pct(row.cost_usd, total_cost)}%",
                          else: "#{Stats.share_pct(row.requests, total_requests)}%"
                        )
                      }
                    />
                    <%= if Decimal.compare(row.cost_usd, Decimal.new(0)) == :gt do %>
                      <Stats.metric_cell
                        label={gettext("Cost")}
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
                <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
                {gettext("By model")}
              </h2>
              <span class="text-[10px] text-base-content/40 hidden sm:inline">
                {if cost_mode?,
                  do: gettext("top %{count} by cost", count: length(model_rows)),
                  else: gettext("top %{count} by requests", count: length(model_rows))}
              </span>
            </div>

            <%= if model_rows != [] do %>
              <ul class="mt-1" id="model-breakdown-list">
                <Stats.ranked_row
                  :for={{row, rank} <- Enum.with_index(model_rows, 1)}
                  rank={rank}
                  title={row.model_name}
                  href={row.model_id && ~p"/stats/models/#{row.model_id}?period=#{@period}"}
                  id={"model-breakdown-row-#{rank}"}
                >
                  <:metrics>
                    <Stats.metric_cell
                      label="Requests"
                      value={Stats.format_number(row.requests)}
                    />
                    <Stats.metric_cell
                      label={gettext("Distribution")}
                      value={
                        if(cost_mode? and Decimal.compare(total_cost, Decimal.new(0)) == :gt,
                          do: "#{Stats.cost_share_pct(row.cost_usd, total_cost)}%",
                          else: "#{Stats.share_pct(row.requests, total_requests)}%"
                        )
                      }
                    />
                    <Stats.metric_cell
                      label={gettext("Providers")}
                      value={Stats.format_number(row.provider_count)}
                    />
                    <%= if Decimal.compare(row.cost_usd, Decimal.new(0)) == :gt do %>
                      <Stats.metric_cell
                        label={gettext("Cost")}
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

        <%!-- Quién lo usa y con qué herramienta: consumidores (usuarios + servicios) y agentes --%>
        <div
          :if={admin? and @top_consumers != []}
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="overview-top-consumers"
        >
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-base">
                <.icon name="hero-users" class="w-5 h-5 text-base-content/60" />
                {gettext("Top consumers")}
              </h2>
              <div class="flex items-center gap-2">
                <span class="text-[10px] text-base-content/40">
                  {gettext("users & services by cost")}
                </span>
                <.link
                  patch={~p"/stats/finops?period=#{@period}"}
                  class="btn btn-xs btn-ghost"
                  id="overview-finops-link"
                >
                  {gettext("FinOps")} →
                </.link>
              </div>
            </div>
            <ul class="mt-1">
              <Stats.ranked_row
                :for={{row, rank} <- Enum.with_index(@top_consumers, 1)}
                rank={rank}
                title={
                  if(row.subject_type == "service",
                    do: "#{row.label} (#{gettext("Service")})",
                    else: row.label
                  )
                }
                href={
                  case {row.subject_type, row.subject_id} do
                    {"user", id} when is_binary(id) -> ~p"/stats/users/#{id}"
                    {"service", id} when is_binary(id) -> ~p"/stats/services/#{id}"
                    _ -> nil
                  end
                }
                id={"overview-consumer-row-#{rank}"}
              >
                <:metrics>
                  <Stats.metric_cell label="Requests" value={Stats.format_number(row.request_count)} />
                  <Stats.metric_cell
                    label={gettext("Share")}
                    value={"#{Stats.cost_share_pct(row.cost_usd, @metrics.cost_usd)}%"}
                  />
                  <Stats.metric_cell
                    label={gettext("Cost")}
                    value={"$" <> Stats.format_decimal(row.cost_usd)}
                    class="text-warning"
                  />
                </:metrics>
              </Stats.ranked_row>
            </ul>
          </div>
        </div>

        <div
          :if={admin? and @top_agents != []}
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="overview-top-agents"
        >
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-base">
                <.icon name="hero-command-line" class="w-5 h-5 text-base-content/60" />
                {gettext("Top agents")}
              </h2>
              <.link
                patch={~p"/stats/agents?period=#{@period}"}
                class="btn btn-xs btn-ghost"
              >
                {gettext("View all")}
              </.link>
            </div>
            <ul class="mt-1">
              <Stats.ranked_row
                :for={{row, rank} <- Enum.with_index(@top_agents, 1)}
                rank={rank}
                title={row.label}
                href={~p"/stats/agents/#{row.key}?period=#{@period}"}
                id={"overview-agent-row-#{rank}"}
              >
                <:leading>
                  <img :if={row.logo} src={row.logo} alt="" class="w-4 h-4 object-contain shrink-0" />
                  <.icon
                    :if={!row.logo}
                    name={row.icon}
                    class="w-4 h-4 text-base-content/60 shrink-0"
                  />
                </:leading>
                <:metrics>
                  <Stats.metric_cell label="Requests" value={Stats.format_number(row.request_count)} />
                  <Stats.metric_cell
                    label={gettext("Share")}
                    value={"#{Stats.cost_share_pct(row.cost_usd, @metrics.cost_usd)}%"}
                  />
                  <Stats.metric_cell
                    label={gettext("Cost")}
                    value={"$" <> Stats.format_decimal(row.cost_usd)}
                    class="text-warning"
                  />
                </:metrics>
              </Stats.ranked_row>
            </ul>
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
          hour_suffix={if today?, do: "UTC", else: gettext("local time")}
          empty_note={
            if today?,
              do: gettext("no traffic in the UTC day yet"),
              else: gettext("no data in the period")
          }
          now_hour={if today?, do: DateTime.utc_now().hour, else: nil}
          metric={@chart_metric}
          toggle_event="set_chart_metric"
        />
      </div>
    </div>
    """
  end

  defp daily_series_labels(series) do
    series
    |> Enum.group_by(& &1.label)
    |> Enum.map(fn {label, rows} ->
      cost =
        Enum.reduce(rows, Decimal.new(0), fn r, acc ->
          Decimal.add(acc, Map.get(r, :total_cost_usd, Decimal.new(0)))
        end)

      {label, cost}
    end)
    |> Enum.sort(fn {_, a}, {_, b} -> Decimal.compare(a, b) != :lt end)
    |> Enum.map(&elem(&1, 0))
  end
end
