defmodule TokengateWeb.StatsLive.Groups do
  @moduledoc """
  Sección profiles (Perfiles de límites) de /stats. Template renderizado por
  `TokengateWeb.StatsLive`; helpers de formato vía `TokengateWeb.StatsHelpers`.

  Se renderiza como una TABLA ÚNICA: puesto (medalla oro/plata/bronce en el
  top 3) + nombre + el consumo y presupuesto de cada perfil en el período. El
  nombre es el enlace al detalle (`/stats/profiles/:id?period=…`), donde viven
  sus métricas, sus miembros y los modelos que consume. El buscador filtra por
  nombre en vivo y el período se elige en el selector del hub.

  Misma estructura que las tablas de proveedores, modelos y agentes. El puesto
  sale de la clasificación por gasto del período — no del listado ordenado o
  filtrado: ordenar por otra columna o escribir en el buscador no renumera las
  filas.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :breakdown_group, :any, required: true
  attr :group_budgets, :any, default: []
  attr :list_search, :any, default: ""
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def groups(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="group-ranking">
        <div class="card-body">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <h2 class="card-title text-base">
                <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60 shrink-0" />
                {gettext("Limit profiles")}
              </h2>
              <p class="text-xs text-base-content/60 mt-1">
                {gettext(
                  "One row per limit profile with its basic information in the period (%{period}). The name opens the detail: its metrics, its members and the models it consumes.",
                  period: Stats.period_label(@period)
                )}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2 shrink-0">
              <Stats.list_search
                :if={Stats.has_data?(@breakdown_group)}
                id="group-list-search"
                value={@list_search}
                placeholder={gettext("Filter by limit profile…")}
              />
              <.link
                href={"/stats/export?type=groups&period=#{@period}"}
                class="btn btn-sm btn-ghost"
                id="csv-groups"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
              </.link>
            </div>
          </div>
          <%= if Stats.has_data?(@breakdown_group) do %>
            <%!-- Puesto = clasificación por consumo del período (completa), no la
                 del listado ordenado o filtrado. --%>
            <% ranks =
              @breakdown_group
              |> Enum.sort(&group_before?/2)
              |> Enum.map(& &1.group_id)
              |> Enum.with_index(1)
              |> Map.new() %>
            <%!-- El buscador filtra las filas en el render: no toca la DB ni las
                 claves del DashboardCache. --%>
            <%!-- El denominador del Share es el total del PERÍODO (lista
                 completa), no el del filtro; el pie suma lo visible. --%>
            <% period_total = Stats.breakdown_total(@breakdown_group) %>
            <% rows = Enum.filter(@breakdown_group, &Stats.matches?(@list_search, &1.group_name)) %>
            <% group_total = Stats.breakdown_total(rows) %>
            <% list_rows = Stats.shown_rows(rows, "group-list", @shown_counts, @per_page) %>
            <div class="mt-3 overflow-x-auto">
              <.table
                id="group-table"
                rows={list_rows}
                row_id={fn row -> "bd-group-#{row.group_id}" end}
                sort_field={@sort_field}
                sort_direction={@sort_direction}
                sort_event="sort"
              >
                <:col :let={row} label={gettext("Rank")} align="center">
                  <span class="inline-flex w-6 justify-center">
                    <%= if rank = Map.get(ranks, row.group_id) do %>
                      <Stats.medal rank={rank} />
                    <% end %>
                  </span>
                </:col>
                <:col :let={row} label={gettext("Limit profile")} field={:group_name}>
                  <.link
                    patch={~p"/stats/profiles/#{row.group_id}?period=#{@period}"}
                    class="link link-hover font-medium inline-flex items-center gap-1"
                    id={"group-link-#{row.group_id}"}
                  >
                    {row.group_name}
                    <.icon name="hero-chevron-right" class="w-3.5 h-3.5 text-base-content/40" />
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
                  tooltip={gettext("Calendar-month spend vs the aggregate cap of its members")}
                >
                  <%= if budget = group_budget_for(@group_budgets, row.group_id) do %>
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
                  <div id="group-list-empty">
                    <.icon name="hero-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                    <p>{gettext("No matches.")}</p>
                  </div>
                </:empty>
              </.table>
            </div>
            <div
              id="group-table-totals"
              class="mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 text-xs"
            >
              <span class="font-semibold text-base-content/70">
                {gettext("Total · %{count} limit profiles", count: length(rows))}
              </span>
              <%= if group_total do %>
                <div class="flex flex-wrap items-baseline gap-x-5 gap-y-1 font-mono tabular-nums text-base-content/80">
                  <span>
                    <span class="text-base-content/40">{gettext("Requests")}</span>
                    <span class="ml-1">{Stats.format_number(group_total.request_count)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cost")}</span>
                    <span class="ml-1">{Stats.money(group_total.cost_usd)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Tokens in")}</span>
                    <span class="ml-1">{Stats.format_number(group_total.prompt_tokens)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Tokens out")}</span>
                    <span class="ml-1">{Stats.format_number(group_total.completion_tokens)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cache %")}</span>
                    <span class="ml-1">
                      {Stats.cache_hit_pct(group_total.prompt_tokens, group_total.cache_read_tokens)}
                    </span>
                  </span>
                </div>
              <% end %>
            </div>
            <Stats.show_more
              key="group-list"
              id="group-list-more"
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

  defp group_budget_for(rows, group_id) do
    Enum.find(rows, fn row -> row.group.id == group_id end)
  end

  defp group_before?(a, b) do
    case Decimal.compare(a.cost_usd, b.cost_usd) do
      :eq -> a.request_count >= b.request_count
      :gt -> true
      :lt -> false
    end
  end
end
