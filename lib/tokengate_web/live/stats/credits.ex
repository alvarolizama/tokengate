defmodule TokengateWeb.StatsLive.Credits do
  @moduledoc """
  Sección Créditos de /stats: gasto por miembro contra sus
  límites de presupuesto, agrupado por grupo, con barras de progreso.

  Los datos los computa `TokengateWeb.StatsLive` (load_budgets) desde los
  contadores de `Tokengate.Budgets` + `DashboardCache`.
  """
  use TokengateWeb, :html

  attr :budgets, :list, required: true
  attr :budgets_by_group, :map, required: true
  attr :group_budgets, :list, required: true
  attr :inactive_by_group, :map, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def credits(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-end">
        <button phx-click="refresh" class="btn btn-ghost btn-sm" id="refresh-credits">
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Actualizar
        </button>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between">
              <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                Miembros
              </p>
              <.icon name="hero-users" class="w-4 h-4 text-base-content/60" />
            </div>
            <p class="mt-1 text-2xl font-bold text-base-content" id="credits-count-total">
              {length(@budgets)}
            </p>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between">
              <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                Por agotarse (&ge;80%)
              </p>
              <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
            </div>
            <p class="mt-1 text-2xl font-bold text-base-content" id="credits-count-near">
              {Enum.count(@budgets, fn b -> is_float(b.daily_pct) and b.daily_pct >= 80.0 end)}
            </p>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between">
              <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                Sin crédito
              </p>
              <.icon name="hero-no-symbol" class="w-4 h-4 text-error" />
            </div>
            <p class="mt-1 text-2xl font-bold text-base-content" id="credits-count-exhausted">
              {Enum.count(@budgets, & &1.exhausted?)}
            </p>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300 shadow-sm" id="group-budgets">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" /> Por grupo
          </h2>
          <p class="text-xs text-base-content/60">
            Tope mensual = budget mensual por usuario.
          </p>
          <div class="overflow-x-auto mt-3">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Grupo</th>
                  <th class="text-right">Miembros</th>
                  <th class="w-64">Gasto mensual real</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={tb <- @group_budgets} id={"group-budget-#{tb.group.id}"}>
                  <td class="font-medium">{tb.group.name}</td>
                  <td class="text-right font-mono">{tb.member_count}</td>
                  <td>
                    <%= if is_nil(tb.monthly_limit_usd) do %>
                      <div class="text-xs text-base-content/60">
                        ${fmt_money(tb.monthly_spend_usd)} · sin límite
                      </div>
                    <% else %>
                      <div class="space-y-1">
                        <div class="flex justify-between text-xs font-mono">
                          <span>${fmt_money(tb.monthly_spend_usd)}</span>
                          <span class="text-base-content/60">
                            de ${fmt_money(tb.monthly_limit_usd)}
                          </span>
                        </div>
                        <progress
                          class={["progress w-full", bar_class(tb.monthly_pct)]}
                          value={bar_value(tb.monthly_pct)}
                          max="100"
                        ></progress>
                      </div>
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-users" class="w-5 h-5 text-base-content/60" /> Por miembro
          </h2>
          <div
            :for={
              {group_id, budgets} <- Enum.sort_by(@budgets_by_group, fn {_, bs} -> -length(bs) end)
            }
            class="space-y-3"
            id={"group-group-#{group_id}"}
          >
            <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
              {hd(budgets).member.group.name}
              <span class="text-xs text-base-content/40">({length(budgets)})</span>
            </h3>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th class="w-48">Usuario</th>
                    <th class="w-56">Mensual</th>
                    <th class="w-56">Diario</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={b <- Enum.take(budgets, Map.get(@shown_counts, group_id, @per_page))}
                    id={"credit-row-#{b.member.id}"}
                  >
                    <td class="font-medium w-48">{b.member.user.email}</td>
                    <td class="w-56">
                      <.budget_bar
                        spend={b.monthly_spend_usd}
                        limit={b.monthly_limit_usd}
                        pct={b.monthly_pct}
                        id={"monthly-bar-#{b.member.id}"}
                      />
                    </td>
                    <td class="w-56">
                      <.budget_bar
                        spend={b.daily_spend_usd}
                        limit={b.daily_limit_usd}
                        pct={b.daily_pct}
                        id={"daily-bar-#{b.member.id}"}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div
              :if={length(budgets) > Map.get(@shown_counts, group_id, @per_page)}
              class="flex justify-center"
            >
              <button
                phx-click="show_more"
                phx-value-group-id={group_id}
                class="btn btn-ghost btn-xs"
                id={"show-more-#{group_id}"}
              >
                Ver más ({length(budgets) - Map.get(@shown_counts, group_id, @per_page)} restantes)
              </button>
            </div>
          </div>
          <div :if={@budgets_by_group == %{}} class="text-center py-8 text-base-content/40">
            Sin miembros registrados.
          </div>
        </div>
      </div>

      <%!-- Inactive members: no spend in current period --%>
      <div :if={@inactive_by_group != %{}} class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-pause-circle" class="w-5 h-5 text-base-content/60" />
            Sin uso en el periodo
          </h2>
          <div
            :for={
              {group_id, budgets} <- Enum.sort_by(@inactive_by_group, fn {_, bs} -> -length(bs) end)
            }
            class="space-y-3"
            id={"inactive-group-#{group_id}"}
          >
            <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
              {hd(budgets).member.group.name}
              <span class="text-xs text-base-content/40">({length(budgets)})</span>
            </h3>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th class="w-48">Usuario</th>
                    <th class="w-48">Último request</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={b <- budgets} id={"inactive-row-#{b.member.id}"}>
                    <td class="font-medium">{b.member.user.email}</td>
                    <td class="text-xs text-base-content/50">
                      <%= if b.last_request_at do %>
                        {Calendar.strftime(b.last_request_at, "%d %b %H:%M")}
                      <% else %>
                        <span class="badge badge-sm badge-ghost">nunca</span>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp fmt_money(nil), do: "—"

  defp fmt_money(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  defp bar_class(pct) when is_float(pct) and pct >= 100.0, do: "progress-error"
  defp bar_class(pct) when is_float(pct) and pct >= 80.0, do: "progress-warning"
  defp bar_class(_), do: "progress-success"

  defp bar_value(nil), do: 0
  defp bar_value(pct), do: min(pct, 100.0)

  attr :spend, :any, required: true
  attr :limit, :any, required: true
  attr :pct, :any, required: true
  attr :id, :string, required: true

  defp budget_bar(assigns) do
    ~H"""
    <%= if is_nil(@limit) do %>
      <div class="text-xs text-base-content/60" id={@id}>
        ${fmt_money(@spend)} · sin límite
      </div>
    <% else %>
      <div class="space-y-1" id={@id}>
        <div class="flex justify-between text-xs font-mono">
          <span>${fmt_money(@spend)}</span>
          <span class="text-base-content/60">de ${fmt_money(@limit)}</span>
        </div>
        <progress
          class={["progress w-full", bar_class(@pct)]}
          value={bar_value(@pct)}
          max="100"
        ></progress>
      </div>
    <% end %>
    """
  end
end
