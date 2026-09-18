defmodule TokengateWeb.StatsLive.Users do
  @moduledoc """
  Sección users de /stats — consumo consolidado por USUARIO (una fila por
  usuario, agregando todas sus membresías de perfil de límites), no por membresía.

  Template renderizado por `TokengateWeb.StatsLive` vía import; helpers de
  formato vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  import TokengateWeb.StatsHelpers, only: [sort_icon: 1]

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
            <.icon name="hero-users" class="w-5 h-5 text-base-content/60" /> Usuarios
          </h2>
          <p class="text-xs text-base-content/60">
            Una fila por usuario con su información básica en el período
            ({Stats.period_label(@period)}). Consolida su perfil de límites y
            el nombre abre el detalle: sus métricas y sus últimos requests.
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
            <%= if rows == [] do %>
              <p class="text-sm text-base-content/40 py-6 text-center" id="user-list-empty">
                {gettext("No matches.")}
              </p>
            <% else %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="user-table">
                  <thead>
                    <tr>
                      <th>
                        <button
                          phx-click="sort"
                          phx-value-field="user_email"
                          class="flex items-center gap-1 hover:text-primary"
                        >
                          {gettext("User")}
                          <.sort_icon
                            field={:user_email}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th>{gettext("Limit profiles")}</th>
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
                      <th class="text-right">{gettext("Cost / req")}</th>
                      <th>
                        Crédito · ciclo
                        <div
                          class="tooltip tooltip-top"
                          data-tip={
                            gettext(
                              "The user spend against their effective monthly cap (their own or inherited from their monthly budget) in the current cycle. With no applicable budget: top-ups only."
                            )
                          }
                        >
                          <.icon
                            name="hero-question-mark-circle"
                            class="w-3.5 h-3.5 text-base-content/40"
                          />
                        </div>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- list_rows} id={"bd-user-#{row.user_id}"}>
                      <td class="font-medium">
                        <.link
                          navigate={~p"/stats/users/#{row.user_id}"}
                          class="link link-hover inline-flex items-center gap-1"
                          id={"user-link-#{row.user_id}"}
                        >
                          {row.user_email}
                        </.link>
                      </td>
                      <td>
                        <div class="flex flex-wrap gap-1">
                          <Stats.group_link
                            :for={group <- row.groups}
                            group_id={group.id}
                            name={group.name}
                            period={@period}
                            id={"user-group-#{row.user_id}-#{group.id}"}
                          />
                        </div>
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
                      <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                      <td class="text-right font-mono text-base-content/70">
                        {cost_per_request(row)}
                      </td>
                      <td class="min-w-[150px]">
                        <%= if budget = @budgets_by_user[row.user_id] do %>
                          <div class="flex items-center gap-2">
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
                      </td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td>Total · {length(rows)} usuarios</td>
                      <td></td>
                      <td class="text-right font-mono">
                        {Stats.format_number(user_total.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(user_total.cost_usd)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(user_total.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(user_total.completion_tokens)}
                      </td>
                      <td></td>
                      <td></td>
                      <td></td>
                    </tr>
                  </tfoot>
                </table>
              </div>
              <Stats.show_more
                key="user-list"
                id="user-list-more"
                top={length(list_rows)}
                total={length(rows)}
              />
            <% end %>
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
