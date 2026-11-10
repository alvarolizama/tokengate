defmodule TokengateWeb.StatsLive.Services do
  @moduledoc """
  Sección services de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  import TokengateWeb.StatsHelpers, only: [sort_icon: 1]

  attr :breakdown_service, :any, required: true
  attr :service_budgets, :any, default: []
  attr :list_search, :any, default: ""
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def services(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-end flex-wrap gap-3">
        <.link
          href="/stats/export?type=services&period=#{@period}"
          class="btn btn-sm btn-ghost"
          id="csv-services"
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
        </.link>
      </div>

      <div class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-base-content/60" /> Servicios
          </h2>
          <p class="text-xs text-base-content/60">
            Una fila por servicio con su información básica en el período
            ({Stats.period_label(@period)}). El nombre abre el detalle: sus métricas
            y los modelos que sirve.
          </p>
          <%= if Stats.has_data?(@breakdown_service) do %>
            <% service_total = Stats.breakdown_total(@breakdown_service) %>
            <%!-- El buscador filtra las filas en el render: no toca la DB ni las
                   claves del DashboardCache. --%>
            <% rows =
              Enum.filter(@breakdown_service, &Stats.matches?(@list_search, &1.service_name)) %>
            <% list_rows = Stats.shown_rows(rows, "service-list", @shown_counts, @per_page) %>
            <div class="mt-3">
              <Stats.list_search
                id="service-list-search"
                value={@list_search}
                placeholder={gettext("Filter by service…")}
              />
            </div>
            <%= if rows == [] do %>
              <p class="text-sm text-base-content/40 py-6 text-center" id="service-list-empty">
                {gettext("No matches.")}
              </p>
            <% else %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="service-table">
                  <thead>
                    <tr>
                      <th>
                        <button
                          phx-click="sort"
                          phx-value-field="service_name"
                          class="flex items-center gap-1 hover:text-primary"
                        >
                          {gettext("Service")}
                          <.sort_icon
                            field={:service_name}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="request_count"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          {gettext("Requests")}
                          <.sort_icon
                            field={:request_count}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="cost_usd"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          {gettext("Cost")}
                          <.sort_icon
                            field={:cost_usd}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="prompt_tokens"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          {gettext("Tokens in")}
                          <.sort_icon
                            field={:prompt_tokens}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="completion_tokens"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          {gettext("Tokens out")}
                          <.sort_icon
                            field={:completion_tokens}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th
                        class="text-right"
                        title={gettext("Percentage of prompt tokens with cache hit")}
                      >
                        {gettext("Cache %")}
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="avg_tps"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          {gettext("TPS")}
                          <.sort_icon
                            field={:avg_tps}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th title={gettext("Calendar-month spend vs the service monthly cap")}>
                        Presupuesto · mes
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- list_rows} id={"bd-service-#{row.service_id}"}>
                      <td class="font-medium">
                        <.link
                          navigate={~p"/stats/services/#{row.service_id}"}
                          class="link link-hover"
                          id={"service-link-#{row.service_id}"}
                          title={gettext("Open the service full stats page")}
                        >{row.service_name}</.link>
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.completion_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.cache_hit_pct(
                          row.prompt_tokens,
                          Map.get(row, :cache_read_tokens, 0)
                        )}
                      </td>
                      <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                      <td class="min-w-[150px]">
                        <%= if budget = service_budget_for(@service_budgets, row.service_id) do %>
                          <div class="flex items-center gap-2">
                            <Stats.budget_bar
                              compact
                              spend={budget.monthly_spend_usd}
                              limit={budget.monthly_limit_usd}
                              pct={budget.monthly_pct}
                            />
                            <Stats.budget_badge pct={budget.monthly_pct} />
                          </div>
                        <% else %>
                          <span class="text-base-content/30">—</span>
                        <% end %>
                      </td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td>Total · {length(@breakdown_service)} servicios</td>
                      <td class="text-right font-mono">
                        {Stats.format_number(service_total.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(service_total.cost_usd)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(service_total.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(service_total.completion_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.cache_hit_pct(
                          service_total.prompt_tokens,
                          service_total.cache_read_tokens
                        )}
                      </td>
                      <td></td>
                      <td></td>
                    </tr>
                  </tfoot>
                </table>
              </div>
            <% end %>
            <Stats.show_more
              key="service-list"
              id="service-list-more"
              top={length(list_rows)}
              total={length(rows)}
            />
          <% else %>
            <p class="text-sm text-base-content/40 py-6 text-center">
              {gettext("No data for this period.")}
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp service_budget_for(rows, service_id) do
    Enum.find(rows, fn row -> row.service.id == service_id end)
  end
end
