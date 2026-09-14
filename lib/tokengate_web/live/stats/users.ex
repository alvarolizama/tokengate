defmodule TokengateWeb.StatsLive.Users do
  @moduledoc """
  Sección users de /stats — consumo consolidado por USUARIO (una fila por
  usuario, agregando todas sus membresías de grupo), no por membresía.

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

      <div class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-users" class="w-5 h-5 text-base-content/60" /> Consumo por usuario
          </h2>
          <p class="text-xs text-base-content/60">
            Una fila por usuario — consolida todas sus membresías de grupo en el período
            ({Stats.period_label(@period)}).
          </p>
          <%= if Stats.has_data?(@breakdown_user) do %>
            <% user_total = Stats.breakdown_total(@breakdown_user) %>
            <div class="overflow-x-auto mt-3">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>
                      <button
                        phx-click="sort"
                        phx-value-field="user_email"
                        class="flex items-center gap-1 hover:text-primary"
                      >
                        Usuario
                        <.sort_icon
                          field={:user_email}
                          current={@sort_field}
                          direction={@sort_direction}
                        />
                      </button>
                    </th>
                    <th>Grupos</th>
                    <th class="text-right">
                      <button
                        phx-click="sort"
                        phx-value-field="request_count"
                        class="flex items-center justify-end gap-1 w-full hover:text-primary"
                      >
                        Requests
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
                        Costo
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
                        Tokens in
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
                        Tokens out
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
                        TPS
                        <.sort_icon
                          field={:avg_tps}
                          current={@sort_field}
                          direction={@sort_direction}
                        />
                      </button>
                    </th>
                    <th class="text-right">Costo / req</th>
                    <th>
                      Presupuesto · mes
                      <div
                        class="tooltip tooltip-top"
                        data-tip="Gasto del mes calendario vs límite agregado de sus membresías"
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
                  <tr :for={row <- @breakdown_user} id={"bd-user-#{row.user_id}"}>
                    <td class="font-medium">
                      <.link navigate={~p"/stats/users/#{row.user_id}"} class="link link-hover">
                        {row.user_email}
                      </.link>
                    </td>
                    <td>
                      <div class="flex flex-wrap gap-1">
                        <span
                          :for={name <- row.group_names}
                          class="badge badge-sm badge-ghost max-w-[140px] truncate"
                          title={name}
                        >
                          {name}
                        </span>
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
                    <td>Total · {length(@breakdown_user)} usuarios</td>
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
          <% else %>
            <p class="text-sm text-base-content/40 py-6 text-center">
              Sin datos para este periodo.
            </p>
          <% end %>
        </div>
      </div>

      <%!-- Top miembros (movido del Resumen; derivado de @breakdown_user, sin queries nuevas) --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="top-members">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-user" class="w-5 h-5 text-base-content/60" /> Top 5 Miembros
          </h2>
          <p class="text-xs text-base-content/60">
            Mayor consumo del período ({Stats.period_label(@period)}).
          </p>
          <%= if Stats.has_data?(@breakdown_user) do %>
            <div class="overflow-x-auto mt-3">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Usuario</th>
                    <th class="text-right">Requests</th>
                    <th class="text-right">Costo</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for row <- @breakdown_user |> Enum.sort_by(& &1.request_count, :desc) |> Enum.take(5) do %>
                    <tr id={"top-member-#{row.user_id}"}>
                      <td class="font-medium truncate max-w-[180px]">{row.user_email}</td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <p class="text-sm text-base-content/40 py-6 text-center">Sin datos.</p>
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
