defmodule TokengateWeb.StatsLive.Users do
  @moduledoc """
  Sección users de /stats — consumo consolidado por USUARIO (una fila por
  usuario, agregando todas sus membresías de perfil de límites), no por membresía.

  Template renderizado por `TokengateWeb.StatsLive` vía import; helpers de
  formato vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :breakdown_user, :any, required: true
  attr :budgets_by_user, :any, default: %{}
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :list_search, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def users(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-end flex-wrap gap-3">
        <.link
          href={"/stats/export?type=logs&period=#{@period}"}
          class="btn btn-sm btn-ghost"
          id="csv-users"
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
        </.link>
      </div>

      <div class="card bg-base-100 border border-base-300 shadow-sm" id="user-ranking">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-users" class="w-5 h-5 text-base-content/60" /> {gettext("Users")}
          </h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "One row per user with its basic information in the period (%{period}). It consolidates their limit profile and the name opens the detail: their metrics and their last requests.",
              period: Stats.period_label(@period)
            )}
          </p>
          <%= if Stats.has_data?(@breakdown_user) do %>
            <% user_total = Stats.breakdown_total(@breakdown_user) %>
            <%!-- El buscador filtra las filas en el render (correo o nombre): no
                 toca la DB ni las claves del DashboardCache. --%>
            <% rows =
              Enum.filter(
                @breakdown_user,
                &Stats.matches?(@list_search, [&1.user_email, &1.user_name])
              ) %>
            <% list_rows = Stats.shown_rows(rows, "user-list", @shown_counts, @per_page) %>
            <div class="mt-3">
              <Stats.list_search
                id="user-list-search"
                value={@list_search}
                placeholder={gettext("Filter by email or name…")}
              />
            </div>
            <div class="mt-3 overflow-x-auto">
              <.table
                id="user-table"
                rows={list_rows}
                row_id={fn row -> "bd-user-#{row.user_id}" end}
                sort_field={@sort_field}
                sort_direction={@sort_direction}
                sort_event="sort"
              >
                <:col :let={row} label={gettext("User")} field={:user_email}>
                  <.link
                    navigate={~p"/stats/users/#{row.user_id}"}
                    class="link link-hover font-medium"
                    id={"user-link-#{row.user_id}"}
                  >
                    {row.user_email}
                  </.link>
                </:col>
                <:col :let={row} label={gettext("Limit profiles")}>
                  <div class="flex flex-wrap gap-1">
                    <Stats.group_link
                      :for={group <- row.groups}
                      group_id={group.id}
                      name={group.name}
                      period={@period}
                      id={"user-group-#{row.user_id}-#{group.id}"}
                    />
                  </div>
                </:col>
                <:col :let={row} label={gettext("Requests")} field={:request_count} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                </:col>
                <:col :let={row} label={gettext("Cost")} field={:cost_usd} align="right">
                  <span class="font-mono tabular-nums">${Stats.format_decimal(row.cost_usd)}</span>
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
                <:col :let={row} label={gettext("TPS")} field={:avg_tps} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_tps(row.avg_tps)}</span>
                </:col>
                <:col :let={row} label={gettext("Cost / req")} align="right">
                  <span class="font-mono tabular-nums text-base-content/70">{cost_per_request(row)}</span>
                </:col>
                <:col
                  :let={row}
                  label={gettext("Credit · cycle")}
                  tooltip={
                    gettext(
                      "The user spend against their effective monthly cap (their own or inherited from their monthly budget) in the current cycle. With no applicable budget: top-ups only."
                    )
                  }
                >
                  <%= if budget = @budgets_by_user[row.user_id] do %>
                    <div class="flex items-center gap-2 min-w-[150px]">
                      <Stats.budget_bar
                        compact
                        spend={budget.monthly_usd}
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
                  <div id="user-list-empty">
                    <.icon name="hero-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                    <p>{gettext("No matches.")}</p>
                  </div>
                </:empty>
              </.table>
            </div>
            <div
              id="user-table-totals"
              class="mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 text-xs"
            >
              <span class="font-semibold text-base-content/70">
                {gettext("Total · %{count} users", count: length(rows))}
              </span>
              <div class="flex flex-wrap items-baseline gap-x-5 gap-y-1 font-mono tabular-nums text-base-content/80">
                <span>
                  <span class="text-base-content/40">{gettext("Requests")}</span>
                  <span class="ml-1">{Stats.format_number(user_total.request_count)}</span>
                </span>
                <span>
                  <span class="text-base-content/40">{gettext("Cost")}</span>
                  <span class="ml-1">${Stats.format_decimal(user_total.cost_usd)}</span>
                </span>
                <span>
                  <span class="text-base-content/40">{gettext("Tokens in")}</span>
                  <span class="ml-1">{Stats.format_number(user_total.prompt_tokens)}</span>
                </span>
                <span>
                  <span class="text-base-content/40">{gettext("Tokens out")}</span>
                  <span class="ml-1">{Stats.format_number(user_total.completion_tokens)}</span>
                </span>
              </div>
            </div>
            <Stats.show_more
              key="user-list"
              id="user-list-more"
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

  defp cost_per_request(%{request_count: 0}), do: "—"

  defp cost_per_request(%{cost_usd: %Decimal{} = cost, request_count: n}) when n > 0 do
    cost
    |> Decimal.div(Decimal.new(n))
    |> Decimal.round(4)
    |> Stats.format_decimal()
  end

  defp cost_per_request(_), do: "—"
end
