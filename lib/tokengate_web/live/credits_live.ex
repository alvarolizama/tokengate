defmodule TokengateWeb.CreditsLive do
  @moduledoc """
  Admin credit overview: every team member's daily/monthly spend against
  their effective budget limits, with progress bars and exhaustion state.

  Data is computed live from the ETS budget counters (`Tokengate.Budgets`),
  so the page self-heals — no alert log to acknowledge.
  """

  use TokengateWeb, :live_view
  alias Tokengate.Budgets

  @reload_interval_ms 1_000
  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Créditos · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:reload_scheduled, false)
      |> assign(:per_page, @per_page)
      |> assign(:shown_counts, %{})
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

  def handle_event("show_more", %{"team-id" => team_id}, socket) do
    shown = Map.get(socket.assigns.shown_counts, team_id, @per_page)

    {:noreply,
     assign(
       socket,
       :shown_counts,
       Map.put(socket.assigns.shown_counts, team_id, shown + @per_page)
     )}
  end

  ## Data loading ----------------------------------------------------------

  defp load_budgets(socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    budgets = Budgets.list_member_budgets(timezone)
    # Reuse the already-loaded member budgets for the team rollup instead of
    # list_team_budgets/1, which would re-query members + spend.
    team_budgets = Budgets.rollup_team_budgets(budgets)

    socket
    |> assign(:budgets, budgets)
    |> assign(:budgets_by_team, Enum.group_by(budgets, fn b -> b.member.team.id end))
    |> assign(:team_budgets, team_budgets)
    |> assign(:inactive_by_team, inactive_members(budgets, timezone))
  end

  ## Template helpers --------------------------------------------------------

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

  defp inactive_members(budgets, _timezone) do
    inactive =
      budgets
      |> Enum.filter(fn b ->
        Decimal.compare(b.daily_spend_usd, Decimal.new(0)) == :eq and
          Decimal.compare(b.monthly_spend_usd, Decimal.new(0)) == :eq
      end)

    last_requests = Budgets.last_requests_by_member_ids(Enum.map(inactive, & &1.member.id))

    inactive
    |> Enum.map(fn b ->
      Map.put(b, :last_request_at, Map.get(last_requests, b.member.id))
    end)
    |> Enum.group_by(fn b -> b.member.team.id end)
  end

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

        <div class="card bg-base-100 border border-base-300 shadow-sm" id="team-budgets">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" /> Por equipo
            </h2>
            <p class="text-xs text-base-content/60">
              Tope mensual = budget mensual por usuario.
            </p>
            <div class="overflow-x-auto mt-3">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Equipo</th>
                    <th class="text-right">Miembros</th>
                    <th class="w-64">Gasto mensual real</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={tb <- @team_budgets} id={"team-budget-#{tb.team.id}"}>
                    <td class="font-medium">{tb.team.name}</td>
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
                {team_id, budgets} <- Enum.sort_by(@budgets_by_team, fn {_, bs} -> -length(bs) end)
              }
              class="space-y-3"
              id={"team-group-#{team_id}"}
            >
              <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
                {hd(budgets).member.team.name}
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
                      :for={b <- Enum.take(budgets, Map.get(@shown_counts, team_id, @per_page))}
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
                :if={length(budgets) > Map.get(@shown_counts, team_id, @per_page)}
                class="flex justify-center"
              >
                <button
                  phx-click="show_more"
                  phx-value-team-id={team_id}
                  class="btn btn-ghost btn-xs"
                  id={"show-more-#{team_id}"}
                >
                  Ver más ({length(budgets) - Map.get(@shown_counts, team_id, @per_page)} restantes)
                </button>
              </div>
            </div>
            <div :if={@budgets_by_team == %{}} class="text-center py-8 text-base-content/40">
              Sin miembros registrados.
            </div>
          </div>
        </div>

        <%!-- Inactive members: no spend in current period --%>
        <div :if={@inactive_by_team != %{}} class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-pause-circle" class="w-5 h-5 text-base-content/60" />
              Sin uso en el periodo
            </h2>
            <div
              :for={
                {team_id, budgets} <- Enum.sort_by(@inactive_by_team, fn {_, bs} -> -length(bs) end)
              }
              class="space-y-3"
              id={"inactive-team-#{team_id}"}
            >
              <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
                {hd(budgets).member.team.name}
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
