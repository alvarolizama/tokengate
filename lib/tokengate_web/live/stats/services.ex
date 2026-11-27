defmodule TokengateWeb.StatsLive.Services do
  @moduledoc """
  Sección services de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

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
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="service-ranking">
        <div class="card-body">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <h2 class="card-title text-base">
                <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-base-content/60 shrink-0" />
                {gettext("Services")}
              </h2>
              <p class="text-xs text-base-content/60 mt-1">
                {gettext(
                  "One row per service with its basic information in the period (%{period}). The name opens the detail: its metrics and the models it serves.",
                  period: Stats.period_label(@period)
                )}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2 shrink-0">
              <Stats.list_search
                :if={Stats.has_data?(@breakdown_service)}
                id="service-list-search"
                value={@list_search}
                placeholder={gettext("Filter by service…")}
              />
              <.link
                href={"/stats/export?type=services&period=#{@period}"}
                class="btn btn-sm btn-ghost"
                id="csv-services"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
              </.link>
            </div>
          </div>
          <%= if Stats.has_data?(@breakdown_service) do %>
            <%!-- El buscador filtra las filas en el render: no toca la DB ni las
                   claves del DashboardCache. --%>
            <%!-- El denominador del Share es el total del PERÍODO; el pie suma
                 sólo las filas visibles (lo que el usuario está mirando). --%>
            <% period_total = Stats.breakdown_total(@breakdown_service) %>
            <% rows =
              Enum.filter(@breakdown_service, &Stats.matches?(@list_search, &1.service_name)) %>
            <% service_total = Stats.breakdown_total(rows) %>
            <% list_rows = Stats.shown_rows(rows, "service-list", @shown_counts, @per_page) %>
            <div class="mt-3 overflow-x-auto">
              <.table
                id="service-table"
                rows={list_rows}
                row_id={fn row -> "bd-service-#{row.service_id}" end}
                sort_field={@sort_field}
                sort_direction={@sort_direction}
                sort_event="sort"
              >
                <:col :let={row} label={gettext("Service")} field={:service_name}>
                  <.link
                    navigate={~p"/stats/services/#{row.service_id}"}
                    class="link link-hover font-medium"
                    id={"service-link-#{row.service_id}"}
                    title={gettext("Open the service full stats page")}
                  >
                    {row.service_name}
                  </.link>
                </:col>
                <:col :let={row} label={gettext("Requests")} field={:request_count} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                </:col>
                <:col :let={row} label={gettext("Cost")} field={:cost_usd} align="right">
                  <span class="font-mono tabular-nums">{Stats.money(row.cost_usd)}</span>
                </:col>
                <:col :let={row} label={gettext("Share")} align="right">
                  <span class="font-mono tabular-nums text-base-content/70">
                    {Stats.cost_share_pct(row.cost_usd, period_total.cost_usd)}%
                  </span>
                </:col>
                <:col :let={row} label={gettext("Cost / req")} align="right">
                  <span class="font-mono tabular-nums text-base-content/70">
                    {Stats.cost_per_request(row.cost_usd, row.request_count)}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Tokens in")} field={:prompt_tokens} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_number(row.prompt_tokens)}</span>
                </:col>
                <:col
                  :let={row}
                  label={gettext("Tokens out")}
                  field={:completion_tokens}
                  align="right"
                >
                  <span class="font-mono tabular-nums">{Stats.format_number(row.completion_tokens)}</span>
                </:col>
                <:col
                  :let={row}
                  label={gettext("Cache %")}
                  align="right"
                  tooltip={gettext("Percentage of prompt tokens with cache hit")}
                >
                  <span class="font-mono tabular-nums">
                    {Stats.cache_hit_pct(row.prompt_tokens, Map.get(row, :cache_read_tokens, 0))}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Errors")} field={:error_count} align="right">
                  <% errs = Map.get(row, :error_count, 0) %>
                  <span class={["font-mono tabular-nums", errs > 0 && "text-warning"]}>
                    {Stats.format_number(errs)}
                  </span>
                </:col>
                <:col :let={row} label={gettext("TPS")} field={:avg_tps} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_tps(row.avg_tps)}</span>
                </:col>
                <:col
                  :let={row}
                  label={gettext("Budget · month")}
                  tooltip={gettext("Calendar-month spend vs the service monthly cap")}
                >
                  <%= if budget = service_budget_for(@service_budgets, row.service_id) do %>
                    <div class="flex items-center gap-2 min-w-[150px]">
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
                </:col>
                <:empty>
                  <div id="service-list-empty">
                    <.icon name="hero-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                    <p>{gettext("No matches.")}</p>
                  </div>
                </:empty>
              </.table>
            </div>
            <div
              id="service-table-totals"
              class="mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 text-xs"
            >
              <span class="font-semibold text-base-content/70">
                {gettext("Total · %{count} services", count: length(rows))}
              </span>
              <%= if service_total do %>
                <div class="flex flex-wrap items-baseline gap-x-5 gap-y-1 font-mono tabular-nums text-base-content/80">
                  <span>
                    <span class="text-base-content/40">{gettext("Requests")}</span>
                    <span class="ml-1">{Stats.format_number(service_total.request_count)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cost")}</span>
                    <span class="ml-1">{Stats.money(service_total.cost_usd)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Tokens in")}</span>
                    <span class="ml-1">{Stats.format_number(service_total.prompt_tokens)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Tokens out")}</span>
                    <span class="ml-1">{Stats.format_number(service_total.completion_tokens)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cache %")}</span>
                    <span class="ml-1">
                      {Stats.cache_hit_pct(
                        service_total.prompt_tokens,
                        service_total.cache_read_tokens
                      )}
                    </span>
                  </span>
                </div>
              <% end %>
            </div>
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
