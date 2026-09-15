defmodule TokengateWeb.StatsLive.Index do
  @moduledoc """
  Sección index de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  import TokengateWeb.KpiHelpers, only: [kpi_cards: 1]

  attr :metrics, :any, required: true
  attr :org_budget, :any, default: nil
  attr :peak_concurrency, :any, required: true
  attr :busiest_hours, :any, required: true
  attr :busiest_minutes, :any, required: true
  attr :hour_usage_stacked, :any, required: true
  attr :model_provider_stacked, :any, required: true
  attr :hovered_hour, :any, required: true
  attr :period, :any, required: true
  attr :timezone, :any, required: true
  attr :budget_reset_hours, :any, required: true
  attr :budget_reset_minutes, :any, required: true
  attr :budget_reset_at, :any, required: true
  attr :current_user, :any, required: true

  def index(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Tope diario global — gasto real (DB) vs kill-switch diario. Con el
           período "hoy" mide el día UTC, la misma ventana que Mantenimiento,
           así que la barra y el badge comparan contra el cap real; con
           ventanas más largas muestra el gasto del período sin barra (el tope
           aplica por día UTC). --%>
      <%= if @org_budget && @current_user && @current_user.global_role == "admin" do %>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="org-budget-card">
          <div class="card-body p-5">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <div class="flex items-center gap-2">
                <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Tope diario global
                </span>
                <%= if @period == "today" do %>
                  <Stats.budget_badge pct={@org_budget.daily_pct} />
                <% end %>
              </div>
              <span
                :if={@org_budget.exempt_count > 0}
                class="badge badge-sm badge-ghost"
                id="org-budget-exempt"
                title="Usuarios, grupos o servicios exentos del tope diario global"
              >
                {@org_budget.exempt_count} exentos
              </span>
            </div>
            <div class="mt-2">
              <%= if @period == "today" do %>
                <Stats.budget_bar
                  spend={@org_budget.daily_spend_usd}
                  limit={@org_budget.daily_cap_usd}
                  pct={@org_budget.daily_pct}
                />
              <% else %>
                <Stats.budget_bar
                  spend={@org_budget.daily_spend_usd}
                  limit={nil}
                  pct={nil}
                />
              <% end %>
            </div>
            <p class="text-xs text-base-content/40 mt-1">
              <%= if @period == "today" do %>
                Gasto del día UTC · todos los sujetos · reinicia en
                <span
                  class="font-mono tabular-nums text-base-content/60 whitespace-nowrap"
                  id="org-budget-reset-countdown"
                  title="Horas y minutos restantes hasta el reinicio del tope (00:00 UTC)"
                  aria-label={
                    "Faltan #{@budget_reset_hours} horas y #{@budget_reset_minutes} minutos para el reinicio del tope"
                  }
                >
                  <span aria-hidden="true">
                    {@budget_reset_hours}<span class="reset-colon">:</span>{@budget_reset_minutes}<span class="text-base-content/40">h</span>
                  </span>
                </span>
                <span id="org-budget-reset-at">
                  ({Stats.format_time(@budget_reset_at, @timezone)} en tu hora local)
                </span>
              <% else %>
                Gasto de {Stats.period_label(@period)} · todos los sujetos · el tope aplica por día UTC
              <% end %>
            </p>
          </div>
        </div>
      <% end %>

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
                  Pico de concurrencia
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
                  Sin datos
                </p>
              <% end %>
            </div>
          </div>
        <% end %>

        <div id="busiest-hours" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <div class="flex items-center justify-between">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                Horas pico
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
                Sin datos
              </p>
            <% end %>
          </div>
        </div>

        <div id="busiest-minutes" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <div class="flex items-center justify-between">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                Minutos pico
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
                Sin datos
              </p>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Patrones de uso: gráficas de modelo/proveedor y hora del día --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" id="usage-patterns">
        <%!-- Card 1: Por modelo y proveedor --%>
        <div
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="model-provider-breakdown"
        >
          <div class="card-body p-4 gap-2">
            <h2 class="card-title text-base">
              <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
              Por modelo y proveedor
            </h2>

            <%= if Stats.model_provider_max(@model_provider_stacked) > 0 do %>
              <% mp_legend = Stats.provider_legend(@model_provider_stacked) %>

              <div class="flex gap-4 mt-2 pt-2 border-t border-base-200">
                <%!-- Chart --%>
                <div class="flex-1 space-y-2">
                  <div
                    :for={row <- @model_provider_stacked}
                    class="group"
                  >
                    <div class="flex items-center gap-2">
                      <%!-- Model label --%>
                      <span class="text-[11px] font-medium text-base-content/70 w-28 truncate shrink-0 text-right">
                        {row.model_name}
                      </span>

                      <%!-- Bar --%>
                      <div class="flex-1 relative h-5 rounded overflow-hidden bg-base-200/50">
                        <div
                          :for={seg <- Stats.provider_segments(row, mp_legend)}
                          class={["h-full inline-block transition-all", seg.color]}
                          style={"width: #{seg.width_pct}%"}
                          title={"#{seg.provider_name}: #{Stats.format_number(seg.requests)} req"}
                        >
                        </div>
                      </div>

                      <%!-- Request count --%>
                      <span class="text-[10px] text-base-content/50 tabular-nums shrink-0 w-12 text-right">
                        {Stats.format_number(row.total_requests)}
                      </span>
                    </div>
                  </div>
                </div>

                <%!-- Legend --%>
                <div class="w-48 shrink-0 border-l border-base-300 pl-4">
                  <div class="text-[10px] font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Proveedores
                  </div>
                  <div class="space-y-2">
                    <div :for={entry <- mp_legend}>
                      <div class="flex items-center gap-1.5">
                        <span class={[
                          "w-2.5 h-2.5 rounded-sm shrink-0",
                          Stats.provider_legend_color(entry.provider_name, mp_legend)
                        ]} />
                        <span class="text-[10px] font-medium truncate flex-1">{entry.provider_name}</span>
                        <span class="text-[9px] text-base-content/50 shrink-0">
                          {Stats.format_number(entry.requests)} req
                        </span>
                        <span
                          :if={Decimal.compare(entry.cost_usd, Decimal.new(0)) == :gt}
                          class="text-[9px] text-warning shrink-0"
                        >
                          ${Stats.format_decimal(entry.cost_usd)}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos en este período.
              </p>
            <% end %>
          </div>
        </div>

        <%!-- Card 2: Uso por hora del día --%>
        <div
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="hour-distribution"
        >
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-base">
                <.icon name="hero-clock" class="w-5 h-5 text-base-content/60" /> Uso por hora del día
              </h2>
              <span class="text-[10px] text-base-content/40 hidden sm:inline">
                gris = sin costo · morada = con costo · escala √
              </span>
            </div>

            <%!-- Hour distribution chart --%>
            <%= if Stats.hour_usage_stacked_max(@hour_usage_stacked) > 0 do %>
              <% max = Stats.hour_usage_stacked_max(@hour_usage_stacked) %>
              <% legend = Stats.legend_data(@hour_usage_stacked, @hovered_hour) %>
              <% y_ticks = Stats.y_axis_ticks(max) %>

              <div class="flex gap-4 mt-2 items-end">
                <%!-- Chart --%>
                <div class="flex-1">
                  <div class="flex gap-2 items-end">
                    <%!-- Y axis labels --%>
                    <div class="relative h-48 w-10 shrink-0">
                      <span
                        :for={tick <- y_ticks}
                        class="absolute right-0 text-[9px] text-base-content/50 tabular-nums -translate-y-1/2"
                        style={"bottom: #{:math.sqrt(tick / max) * 100}%"}
                      >
                        {Stats.format_number(tick)}
                      </span>
                      <span class="absolute right-0 bottom-0 text-[9px] text-base-content/50 tabular-nums translate-y-1/2">
                        0
                      </span>
                    </div>

                    <div class="relative flex-1">
                      <%!-- Gridlines --%>
                      <div class="absolute inset-0 pointer-events-none">
                        <div
                          :for={tick <- y_ticks}
                          class="absolute left-0 right-0 border-t border-base-300/50 border-dashed"
                          style={"bottom: #{:math.sqrt(tick / max) * 100}%"}
                        />
                      </div>

                      <div class="flex items-end gap-[3px] h-48 relative">
                        <div
                          :for={row <- @hour_usage_stacked}
                          class="group relative flex-1 flex flex-col items-center justify-end h-full"
                          phx-mouseover="hour_hover"
                          phx-value-hour={row.hour}
                          phx-mouseleave="hour_leave"
                        >
                          <% height_pct = Stats.hour_usage_bar_height(row.total_requests, max) %>
                          <% segments = Stats.bar_segments(row) %>

                          <%!-- Tooltip --%>
                          <div class="hidden group-hover:block absolute -top-1 -translate-y-full left-1/2 -translate-x-1/2 z-20 pointer-events-none">
                            <div class="bg-base-300 text-base-content text-[10px] rounded-md px-2.5 py-1.5 shadow-lg whitespace-nowrap">
                              <div class="font-semibold">
                                {Stats.hour_label(row.hour)} · {Stats.format_number(
                                  row.total_requests
                                )} req
                              </div>
                              <div
                                :if={row.free_requests > 0}
                                class="text-base-content/70"
                              >
                                sin costo: {Stats.format_number(row.free_requests)}
                              </div>
                              <div
                                :if={row.paid_requests > 0}
                                class="text-base-content/70"
                              >
                                con costo: {Stats.format_number(row.paid_requests)}
                              </div>
                              <div
                                :for={m <- Stats.paid_models_for_tooltip(row)}
                                class="text-base-content/50 flex justify-between gap-3"
                              >
                                <span class="truncate max-w-[140px]">{m.model}</span>
                                <span class="tabular-nums shrink-0">{Stats.format_number(m.requests)}</span>
                              </div>
                            </div>
                          </div>

                          <div
                            class={[
                              "w-full rounded-t transition-all relative overflow-hidden cursor-pointer",
                              if(@hovered_hour == row.hour,
                                do: "ring-2 ring-primary",
                                else: ""
                              )
                            ]}
                            style={"height: #{height_pct}%"}
                          >
                            <%= if segments == [] do %>
                              <div class="w-full h-full bg-base-300/30" />
                            <% else %>
                              <div class="flex flex-col-reverse h-full w-full">
                                <div
                                  :for={seg <- segments}
                                  class={["w-full", seg.color]}
                                  style={"height: #{seg.height_pct}%"}
                                />
                              </div>
                            <% end %>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>

                  <%!-- Hour labels --%>
                  <div class="flex gap-[3px] mt-1 ml-12">
                    <span :for={row <- @hour_usage_stacked} class="flex-1 text-center">
                      <span
                        :if={rem(row.hour, 3) == 0}
                        class={[
                          "text-[10px]",
                          if(rem(row.hour, 6) == 0,
                            do: "text-base-content/60 font-medium",
                            else: "text-base-content/40"
                          )
                        ]}
                      >
                        {Stats.hour_label(row.hour)}
                      </span>
                    </span>
                  </div>
                </div>

                <%!-- Legend panel --%>
                <div class="w-56 shrink-0 border-l border-base-300 pl-4">
                  <div class="text-[10px] font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    <%= if legend.hovered_hour do %>
                      {Stats.hour_label(legend.hovered_hour)} hrs
                    <% else %>
                      Total período
                    <% end %>
                  </div>

                  <%!-- Free entry --%>
                  <div :if={legend.free_requests > 0} class="mb-2">
                    <div class="flex items-center gap-1.5">
                      <span class="w-2.5 h-2.5 rounded-sm shrink-0 bg-base-300/30" />
                      <span class="text-[10px] font-medium flex-1">Sin costo</span>
                      <span class="text-[9px] text-base-content/50 shrink-0">
                        {Stats.format_number(legend.free_requests)} req
                      </span>
                    </div>
                  </div>

                  <%!-- Charged-cost model breakdown --%>
                  <div class="space-y-2.5">
                    <div :for={entry <- legend.paid_entries}>
                      <div class="flex items-center gap-1.5">
                        <span class="w-2.5 h-2.5 rounded-sm shrink-0 bg-primary" />
                        <span class="text-[10px] font-medium truncate flex-1">{entry.model}</span>
                        <span class="text-[9px] text-base-content/50 shrink-0">
                          {Stats.format_number(entry.requests)} req
                        </span>
                        <span
                          :if={Decimal.compare(entry.cost_usd, Decimal.new(0)) == :gt}
                          class="text-[9px] text-warning shrink-0"
                        >
                          ${Stats.format_decimal(entry.cost_usd)}
                        </span>
                      </div>
                    </div>
                  </div>

                  <%!-- Totals --%>
                  <div class="mt-3 pt-2 border-t border-base-300">
                    <div class="text-[10px] font-semibold">
                      {Stats.format_number(legend.total_requests)} requests
                    </div>
                    <div
                      :if={Decimal.compare(legend.total_cost_usd, Decimal.new(0)) == :gt}
                      class="text-[10px] text-warning font-medium"
                    >
                      ${Stats.format_decimal(legend.total_cost_usd)} total
                    </div>
                  </div>
                </div>
              </div>
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos en este período.
              </p>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
