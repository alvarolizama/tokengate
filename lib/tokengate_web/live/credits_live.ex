defmodule TokengateWeb.CreditsLive do
  @moduledoc """
  Admin credit overview: every team member's daily/monthly spend against
  their effective budget limits, with progress bars and exhaustion state.

  Data is computed live from the ETS budget counters (`Tokengate.Budgets`),
  so the page self-heals — no alert log to acknowledge.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Budgets
  alias Tokengate.Metrics.Rollup

  @reload_interval_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Créditos · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:reload_scheduled, false)
      |> require_admin_hook()
      |> load_budgets()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
    end

    {:ok, socket}
  end

  # Defense-in-depth: the router already gates this LiveView behind
  # live_session :admin, but a malicious client could fire events directly
  # over the WebSocket. Halt every event for non-admins.
  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  @impl true
  def handle_info({:new_log, _log}, socket) do
    # Coalesce reloads: every proxied request broadcasts on this topic, so a
    # busy proxy would otherwise trigger a members query per request.
    if socket.assigns[:reload_scheduled] do
      {:noreply, socket}
    else
      Process.send_after(self(), :reload_budgets, @reload_interval_ms)
      {:noreply, assign(socket, :reload_scheduled, true)}
    end
  end

  def handle_info(:reload_budgets, socket) do
    {:noreply,
     socket
     |> assign(:reload_scheduled, false)
     |> load_budgets()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_budgets(socket)}
  end

  ## Data loading ----------------------------------------------------------

  defp load_budgets(socket) do
    budgets = Budgets.list_member_budgets()
    team_budgets = Budgets.list_team_budgets()

    # Ahorro del mes en curso desde los logs (fuente durable). El gasto
    # viene de los contadores ETS; el ahorro no se trackea en ETS, así que
    # se calcula del mes calendario igual que el contador mensual.
    month_start = beginning_of_month()
    team_savings = savings_by_team(month_start)
    member_savings = savings_by_member(month_start)

    socket
    |> assign(:budgets, budgets)
    |> assign(:team_budgets, team_budgets)
    |> assign(:team_savings, team_savings)
    |> assign(:member_savings, member_savings)
  end

  defp beginning_of_month do
    now = DateTime.utc_now()
    %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp savings_by_team(from) do
    Rollup.breakdown_by_team(from: from)
    |> Map.new(fn row -> {row.team_id, row.savings_usd} end)
  end

  defp savings_by_member(from) do
    Rollup.breakdown_by_member(nil, from: from)
    |> Map.new(fn row -> {row.team_member_id, row.savings_usd} end)
  end

  ## Template helpers --------------------------------------------------------

  defp fmt_money(nil), do: "—"

  defp fmt_money(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  defp status_for(%{exhausted?: true}), do: {:error, "Agotado"}

  defp status_for(%{daily_pct: daily}) do
    near = is_float(daily) and daily >= 80.0

    cond do
      near -> {:warning, "Por agotarse"}
      is_float(daily) -> {:success, "OK"}
      true -> {:ghost, "Sin límite"}
    end
  end

  defp bar_class(pct) when is_float(pct) and pct >= 100.0, do: "progress-error"
  defp bar_class(pct) when is_float(pct) and pct >= 80.0, do: "progress-warning"
  defp bar_class(_), do: "progress-success"

  defp bar_value(nil), do: 0
  defp bar_value(pct), do: min(pct, 100.0)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.header>
            Créditos
            <:subtitle>Gasto de cada miembro contra sus límites de presupuesto</:subtitle>
          </.header>
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
                {Enum.count(@budgets, fn b -> match?({:warning, _}, status_for(b)) end)}
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

        <div class="card bg-base-100 border border-base-300 shadow-sm" id="team-budgets">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" /> Por equipo
            </h2>
            <p class="text-xs text-base-content/60">
              Tope diario = suma de los límites de cada miembro. Ahorro = estimado de mercado
              menos lo realmente pagado en el mes.
            </p>
            <div class="overflow-x-auto mt-3">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Equipo</th>
                    <th class="text-right">Miembros</th>
                    <th class="w-64">Gasto diario real</th>
                    <th class="text-right">Ahorro del mes</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={tb <- @team_budgets} id={"team-budget-#{tb.team.id}"}>
                    <td class="font-medium">{tb.team.name}</td>
                    <td class="text-right font-mono">{tb.member_count}</td>
                    <td>
                      <%= if is_nil(tb.daily_limit_usd) do %>
                        <div class="text-xs text-base-content/60">
                          ${fmt_money(tb.daily_spend_usd)} · sin límite
                        </div>
                      <% else %>
                        <div class="space-y-1">
                          <div class="flex justify-between text-xs font-mono">
                            <span>${fmt_money(tb.daily_spend_usd)}</span>
                            <span class="text-base-content/60">
                              de ${fmt_money(tb.daily_limit_usd)}
                            </span>
                          </div>
                          <progress
                            class={["progress w-full", bar_class(tb.daily_pct)]}
                            value={bar_value(tb.daily_pct)}
                            max="100"
                          ></progress>
                        </div>
                      <% end %>
                    </td>
                    <td class="text-right font-mono text-success">
                      ${fmt_money(Map.get(@team_savings, tb.team.id, Decimal.new(0)))}
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
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Usuario</th>
                    <th>Equipo</th>
                    <th class="w-56">Diario</th>
                    <th class="w-56">Mensual (sin límite)</th>
                    <th class="text-right">Ahorro del mes</th>
                    <th>Estado</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={b <- @budgets} id={"credit-row-#{b.member.id}"}>
                    <td class="font-medium">{b.member.user.email}</td>
                    <td>{b.member.team.name}</td>
                    <td>
                      <.budget_bar
                        spend={b.daily_spend_usd}
                        limit={b.daily_limit_usd}
                        pct={b.daily_pct}
                        id={"daily-bar-#{b.member.id}"}
                      />
                    </td>
                    <td>
                      <div class="text-xs text-base-content/40 text-center">—</div>
                    </td>
                    <td
                      class="text-right font-mono text-success"
                      id={"member-savings-#{b.member.id}"}
                    >
                      ${fmt_money(Map.get(@member_savings, b.member.id, Decimal.new(0)))}
                    </td>
                    <td>
                      <% {style, label} = status_for(b) %>
                      <span class={"badge badge-#{style}"} id={"status-#{b.member.id}"}>
                        {label}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

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
