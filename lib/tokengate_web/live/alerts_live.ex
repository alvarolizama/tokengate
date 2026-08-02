defmodule TokengateWeb.AlertsLive do
  @moduledoc """
  Centralized alert dashboard: credentials in error, open circuit breakers,
  and recent request errors (4xx/5xx). All actionable inline.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers
  alias Tokengate.Repo
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Providers.Provider

  @error_window_hours 24
  @error_limit 20

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Alertas · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:reload_scheduled, false)
      |> assign(:errors_refresh_scheduled, false)
      |> require_admin_hook()
      |> load_alerts()

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
  def handle_info({:new_log, log}, socket) do
    # Coalesce error reloads: during a burst of upstream 5xx, one DB query
    # per broadcast would hammer the database. Cap at one reload per second.
    socket =
      if (log.status_code && log.status_code >= 400) and
           not socket.assigns[:errors_refresh_scheduled] do
        Process.send_after(self(), :reload_recent_errors, 1_000)
        assign(socket, :errors_refresh_scheduled, true)
      else
        socket
      end

    # Budget spend changes on every request; coalesce the reload so a busy
    # proxy doesn't trigger a members query per request.
    if socket.assigns[:reload_scheduled] do
      {:noreply, socket}
    else
      Process.send_after(self(), :reload_budget_alerts, 1_000)
      {:noreply, assign(socket, :reload_scheduled, true)}
    end
  end

  def handle_info(:reload_recent_errors, socket) do
    {:noreply,
     socket
     |> assign(:errors_refresh_scheduled, false)
     |> load_recent_errors()}
  end

  def handle_info(:reload_budget_alerts, socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    {:noreply,
     socket
     |> assign(:reload_scheduled, false)
     |> assign(:budget_exhausted, Tokengate.Budgets.list_exhausted_member_budgets(timezone))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("reactivate_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    if cred.status == "error" do
      case Providers.reactivate_credential(cred) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credencial reactivada.")
           |> load_alerts()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo reactivar la credencial.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Solo se pueden reactivar credenciales en error.")}
    end
  end

  def handle_event("reset_breaker", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    Tokengate.Routing.CircuitBreakerManager.reset(cred.id)

    {:noreply,
     socket
     |> put_flash(:info, "Circuit breaker reseteado.")
     |> load_alerts()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_alerts(socket)}
  end

  ## Data loading ----------------------------------------------------------

  defp load_alerts(socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    credentials =
      from(c in Providers.Credential,
        join: p in assoc(c, :provider),
        where: c.status == "error",
        preload: [provider: p],
        order_by: [desc: c.error_at]
      )
      |> Repo.all()

    # Breaker alerts: read the open breakers straight from the Registry
    # (one sweep), then load ONLY those credentials from the DB — instead of
    # loading every credential + one GenServer call per credential and
    # filtering in memory.
    open = Tokengate.Routing.CircuitBreakerManager.open_breakers()
    open_ids = Map.keys(open)

    open_creds =
      if open_ids == [] do
        []
      else
        from(c in Providers.Credential,
          join: p in assoc(c, :provider),
          where: c.id in ^open_ids,
          preload: [provider: p]
        )
        |> Repo.all()
      end

    creds_by_id = Map.new(open_creds, &{&1.id, &1})

    breaker_alerts =
      Enum.flat_map(open, fn {cred_id, details} ->
        case creds_by_id do
          %{^cred_id => cred} -> [{cred, details}]
          _ -> []
        end
      end)

    # Error counts per credential in the last 24h (for breaker table)
    since = DateTime.utc_now() |> DateTime.add(-@error_window_hours * 3600, :second)

    cred_error_counts =
      from(rl in RequestLog,
        where: rl.status_code >= 400 and rl.inserted_at >= ^since,
        group_by: [rl.api_key_prefix, rl.provider_id],
        select: %{
          api_key_prefix: rl.api_key_prefix,
          provider_id: rl.provider_id,
          count: count(rl.id)
        }
      )
      |> Repo.all()

    # Activity stats for exhausted members (requests today, last request, top provider)
    budget_activity = load_budget_activity(timezone)

    socket
    |> assign(:error_credentials, credentials)
    |> assign(:breaker_alerts, breaker_alerts)
    |> assign(:cred_error_counts, cred_error_counts)
    |> assign(:budget_exhausted, Tokengate.Budgets.list_exhausted_member_budgets(timezone))
    |> assign(:budget_activity, budget_activity)
    |> load_recent_errors()
  end

  defp load_budget_activity(timezone) do
    today_start = Tokengate.Periods.start_of_day_utc(timezone)

    # Get today's stats per team member
    activity_query =
      from(rl in RequestLog,
        where: rl.inserted_at >= ^today_start,
        group_by: rl.team_member_id,
        select: %{
          team_member_id: rl.team_member_id,
          requests_today: count(rl.id),
          last_request: max(rl.inserted_at)
        }
      )

    # Get top provider per team member today
    top_provider_query =
      from(rl in RequestLog,
        where: rl.inserted_at >= ^today_start and not is_nil(rl.provider_id),
        group_by: [rl.team_member_id, rl.provider_id],
        select: %{
          team_member_id: rl.team_member_id,
          provider_id: rl.provider_id,
          request_count: count(rl.id)
        }
      )

    activity_data = Repo.all(activity_query) |> Map.new(fn a -> {a.team_member_id, a} end)

    top_providers =
      Repo.all(top_provider_query)
      |> Enum.group_by(fn t -> t.team_member_id end)
      |> Map.new(fn {member_id, providers} ->
        top = Enum.max_by(providers, fn p -> p.request_count end)
        {member_id, top.provider_id}
      end)

    # Resolve provider names
    provider_names =
      from(p in Provider, select: p)
      |> Repo.all()
      |> Map.new(fn p -> {p.id, p.name} end)

    activity_data
    |> Map.new(fn {member_id, activity} ->
      top_provider_id = Map.get(top_providers, member_id)
      top_provider_name = if top_provider_id, do: Map.get(provider_names, top_provider_id, "—")

      {member_id,
       %{
         requests_today: activity.requests_today,
         last_request: activity.last_request,
         top_provider: top_provider_name
       }}
    end)
  end

  defp load_recent_errors(socket) do
    since = DateTime.utc_now() |> DateTime.add(-@error_window_hours * 3600, :second)

    errors =
      from(rl in RequestLog,
        where: rl.status_code >= 400 and rl.inserted_at >= ^since,
        order_by: [desc: rl.inserted_at],
        limit: ^@error_limit,
        preload: [:provider, team_member: [:user, :team]]
      )
      |> Repo.all()

    assign(socket, :recent_errors, errors)
  end

  ## Helpers ---------------------------------------------------------------

  defp fmt_dt(nil, _timezone), do: "—"

  defp fmt_dt(%DateTime{} = dt, timezone) do
    TokengateWeb.TimezoneHelper.format_datetime_short(dt, timezone)
  end

  defp fmt_money(nil), do: "—"

  defp fmt_money(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  defp budget_periods(%{monthly_exhausted?: true}), do: "mensual"
  defp budget_periods(_), do: "—"

  defp breaker_label(:closed), do: "Cerrado"
  defp breaker_label(:open), do: "Abierto"
  defp breaker_label(:half_open), do: "Half-Open"
  defp breaker_label(_), do: "—"

  defp reason_label(nil), do: "—"
  defp reason_label(:server_error), do: "Error servidor"
  defp reason_label(:timeout), do: "Timeout"
  defp reason_label(:rate_limited), do: "Rate limited"
  defp reason_label(:auth_error), do: "Error auth"
  defp reason_label(:client_error), do: "Error cliente"
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(reason), do: to_string(reason)

  defp status_class_for(status_code) when status_code >= 500, do: "badge-error"
  defp status_class_for(status_code) when status_code >= 400, do: "badge-warning"
  defp status_class_for(_), do: "badge-ghost"

  defp api_key_prefix(nil), do: "—"

  defp api_key_prefix(encrypted) when is_binary(encrypted) and byte_size(encrypted) > 8 do
    String.slice(encrypted, 0, 8) <> "…"
  end

  defp api_key_prefix(encrypted), do: encrypted

  defp errors_for_credential(cred, error_counts) do
    # Match by api_key_prefix (derived from encrypted key) and provider_id
    prefix = api_key_prefix(cred.api_key_encrypted)
    provider_id = cred.provider_id

    error_counts
    |> Enum.filter(fn ec ->
      ec.api_key_prefix == prefix && ec.provider_id == provider_id
    end)
    |> Enum.map(& &1.count)
    |> Enum.sum()
  end

  defp fmt_duration(nil), do: "—"

  defp fmt_duration(%DateTime{} = opened_at) do
    diff = DateTime.diff(DateTime.utc_now(), opened_at, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      diff < 86_400 -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
      true -> "#{div(diff, 86_400)}d #{div(rem(diff, 86_400), 3600)}h"
    end
  end

  defp fmt_latency(nil), do: "—"
  defp fmt_latency(ms) when ms < 1000, do: "#{ms}ms"
  defp fmt_latency(ms), do: "#{Float.round(ms / 1000, 1)}s"

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.header>
            Alertas
            <:subtitle>Problemas activos y errores recientes</:subtitle>
          </.header>
          <button phx-click="refresh" class="btn btn-ghost btn-sm" id="refresh-alerts">
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Actualizar
          </button>
        </div>

        <%!-- Summary --%>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Credenciales en error
                </p>
                <.icon
                  name="hero-exclamation-circle"
                  class="w-4 h-4 text-error"
                />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="alert-count-creds">
                {length(@error_credentials)}
              </p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Breakers abiertos
                </p>
                <.icon name="hero-shield-exclamation" class="w-4 h-4 text-warning" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="alert-count-breakers">
                {length(@breaker_alerts)}
              </p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Miembros sin crédito
                </p>
                <.icon name="hero-banknotes" class="w-4 h-4 text-error" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="alert-count-budgets">
                {length(@budget_exhausted)}
              </p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Errores (24h)
                </p>
                <.icon name="hero-bug-ant" class="w-4 h-4 text-error" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="alert-count-errors">
                {length(@recent_errors)}
              </p>
            </div>
          </div>
        </div>

        <%!-- All clear --%>
        <div
          :if={
            @error_credentials == [] and @breaker_alerts == [] and @recent_errors == [] and
              @budget_exhausted == []
          }
          class="text-center py-12 text-base-content/40"
          id="alerts-empty"
        >
          <.icon name="hero-check-circle" class="w-10 h-10 mx-auto mb-2 text-success" />
          <p>No hay alertas activas. Todo funciona correctamente.</p>
        </div>

        <%!-- Credentials in error --%>
        <div :if={@error_credentials != []} class="space-y-2">
          <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
            Credenciales deshabilitadas por error
          </h3>
          <div class="card bg-base-100 border border-error/30 shadow-sm">
            <div class="card-body p-0">
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Proveedor</th>
                      <th>Alias</th>
                      <th>API Key</th>
                      <th>Endpoint</th>
                      <th>Razón</th>
                      <th>Error</th>
                      <th>Cuándo</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={cred <- @error_credentials} id={"alert-cred-#{cred.id}"}>
                      <td class="font-medium">{cred.provider.name}</td>
                      <td>{cred.name || "—"}</td>
                      <td class="font-mono text-xs">{api_key_prefix(cred.api_key_encrypted)}</td>
                      <td
                        class="text-xs text-base-content/70 max-w-[200px] truncate"
                        title={cred.provider.base_url}
                      >
                        {cred.provider.base_url}
                      </td>
                      <td>
                        <code class="text-xs text-error">{cred.error_reason || "auth_error"}</code>
                      </td>
                      <td class="text-xs text-base-content/70 max-w-xs">
                        <span :if={cred.error_message} class="line-clamp-2" title={cred.error_message}>
                          {cred.error_message}
                        </span>
                        <span :if={!cred.error_message} class="text-base-content/30">—</span>
                      </td>
                      <td class="text-xs text-base-content/50">{fmt_dt(cred.error_at, @timezone)}</td>
                      <td class="text-right">
                        <button
                          phx-click="reactivate_credential"
                          phx-value-id={cred.id}
                          class="btn btn-xs btn-warning"
                          id={"alert-reactivate-#{cred.id}"}
                        >
                          <.icon name="hero-arrow-path" class="w-3 h-3" /> Reactivar
                        </button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>

        <%!-- Open circuit breakers --%>
        <div :if={@breaker_alerts != []} class="space-y-2">
          <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
            Circuit breakers abiertos
          </h3>
          <div class="card bg-base-100 border border-warning/30 shadow-sm">
            <div class="card-body p-0">
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Proveedor</th>
                      <th>Alias</th>
                      <th>API Key</th>
                      <th>Estado</th>
                      <th>Razón</th>
                      <th>Fallos</th>
                      <th>Abierto desde</th>
                      <th>Errores 24h</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{cred, details} <- @breaker_alerts} id={"alert-breaker-#{cred.id}"}>
                      <td class="font-medium">{cred.provider.name}</td>
                      <td>{cred.name || "—"}</td>
                      <td class="font-mono text-xs">{api_key_prefix(cred.api_key_encrypted)}</td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          details.state == :open && "badge-error",
                          details.state == :half_open && "badge-warning"
                        ]}>
                          {breaker_label(details.state)}
                        </span>
                      </td>
                      <td class="text-sm">{reason_label(details.last_reason)}</td>
                      <td class="text-sm tabular-nums">{details.failures}</td>
                      <td class="text-sm">{fmt_duration(details.opened_at)}</td>
                      <td class="text-sm tabular-nums">
                        {errors_for_credential(cred, @cred_error_counts)}
                      </td>
                      <td class="text-right">
                        <button
                          phx-click="reset_breaker"
                          phx-value-id={cred.id}
                          class="btn btn-xs btn-ghost"
                          id={"alert-reset-breaker-#{cred.id}"}
                        >
                          <.icon name="hero-arrow-path" class="w-3 h-3" /> Reset breaker
                        </button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>

        <%!-- Members out of budget --%>
        <div :if={@budget_exhausted != []} class="space-y-2">
          <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
            Miembros sin crédito
          </h3>
          <div class="card bg-base-100 border border-error/30 shadow-sm">
            <div class="card-body p-0">
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Usuario</th>
                      <th>Equipo</th>
                      <th>Límite agotado</th>
                      <th>Gasto mes</th>
                      <th>Gasto hoy</th>
                      <th>Requests hoy</th>
                      <th>Proveedor top (hoy)</th>
                      <th>Último request</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={b <- @budget_exhausted} id={"alert-budget-#{b.member.id}"}>
                      <td class="font-medium">{b.member.user.email}</td>
                      <td>{b.member.team.name}</td>
                      <td>
                        <span class="badge badge-sm badge-error">
                          {budget_periods(b)}
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        ${fmt_money(b.monthly_spend_usd)}
                        <span :if={b.monthly_limit_usd} class="text-base-content/50">
                          / ${fmt_money(b.monthly_limit_usd)}
                        </span>
                      </td>
                      <td class="font-mono text-xs">
                        ${fmt_money(b.daily_spend_usd)}
                      </td>
                      <td class="text-sm tabular-nums">
                        {Map.get(@budget_activity, b.member.id, %{}) |> Map.get(:requests_today, 0)}
                      </td>
                      <td class="text-sm">
                        {Map.get(@budget_activity, b.member.id, %{}) |> Map.get(:top_provider, "—")}
                      </td>
                      <td class="text-xs text-base-content/50">
                        {Map.get(@budget_activity, b.member.id, %{})
                        |> Map.get(:last_request)
                        |> fmt_dt(@timezone)}
                      </td>
                      <td class="text-right">
                        <.link
                          navigate={~p"/dashboard/credits"}
                          class="btn btn-xs btn-ghost"
                          id={"alert-budget-credits-#{b.member.id}"}
                        >
                          Ver créditos
                        </.link>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>

        <%!-- Recent request errors --%>
        <div :if={@recent_errors != []} class="space-y-2">
          <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
            Errores recientes (últimas 24h)
          </h3>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-0">
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Fecha</th>
                      <th>Estado</th>
                      <th>Modelo</th>
                      <th>Modelo real</th>
                      <th>Proveedor</th>
                      <th>Usuario</th>
                      <th>Equipo</th>
                      <th>API Key</th>
                      <th>Motivo</th>
                      <th>Prov. status</th>
                      <th>Latencia</th>
                      <th>Costo</th>
                      <th>Stream</th>
                      <th>Agente</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={log <- @recent_errors} id={"alert-error-#{log.id}"}>
                      <td class="whitespace-nowrap text-sm">{fmt_dt(log.inserted_at, @timezone)}</td>
                      <td>
                        <span class={["badge badge-sm", status_class_for(log.status_code)]}>
                          {log.status_code}
                        </span>
                      </td>
                      <td class="text-sm">{log.model_requested}</td>
                      <td class="text-xs text-base-content/60">
                        {if log.model_responded != log.model_requested,
                          do: log.model_responded,
                          else: "—"}
                      </td>
                      <td class="text-sm">
                        {(log.provider && log.provider.name) || "—"}
                      </td>
                      <td class="text-sm font-mono">
                        {(log.team_member && log.team_member.user && log.team_member.user.email) ||
                          "—"}
                      </td>
                      <td class="text-sm">
                        {(log.team_member && log.team_member.team && log.team_member.team.name) || "—"}
                      </td>
                      <td class="text-sm font-mono">
                        {log.api_key_prefix || "—"}
                      </td>
                      <td class="text-sm">
                        <span :if={log.error_reason} class="badge badge-sm badge-ghost">
                          {log.error_reason}
                        </span>
                        <span :if={!log.error_reason}>—</span>
                      </td>
                      <td class="text-sm tabular-nums">
                        {log.provider_status_code || "—"}
                      </td>
                      <td class="text-sm tabular-nums">
                        {fmt_latency(log.latency_ms)}
                      </td>
                      <td class="text-sm font-mono tabular-nums">
                        {if Decimal.compare(log.provider_cost_usd || 0, 0) == :gt,
                          do: "$" <> fmt_money(log.provider_cost_usd),
                          else: "—"}
                      </td>
                      <td>
                        <span :if={log.streaming} class="badge badge-xs badge-ghost">SSE</span>
                        <span :if={!log.streaming} class="text-base-content/30">—</span>
                      </td>
                      <td>
                        <span class="badge badge-sm badge-ghost">{log.agent_type}</span>
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
end
