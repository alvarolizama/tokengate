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

  @error_window_hours 24
  @error_limit 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Alertas · Tokengate")
      |> load_alerts()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:new_log, log}, socket) do
    if log.status_code && log.status_code >= 400 do
      {:noreply, load_recent_errors(socket)}
    else
      {:noreply, socket}
    end
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
    credentials =
      from(c in Providers.Credential,
        join: p in assoc(c, :provider),
        where: c.status == "error",
        preload: [provider: p],
        order_by: [desc: c.error_at]
      )
      |> Repo.all()

    # All credential IDs (for breaker status lookup)
    all_creds =
      from(c in Providers.Credential,
        join: p in assoc(c, :provider),
        preload: [provider: p]
      )
      |> Repo.all()

    breaker_alerts =
      all_creds
      |> Enum.map(fn cred ->
        {cred, Tokengate.Routing.CircuitBreakerManager.status(cred.id)}
      end)
      |> Enum.filter(fn {_cred, status} -> status != :closed end)

    socket
    |> assign(:error_credentials, credentials)
    |> assign(:breaker_alerts, breaker_alerts)
    |> load_recent_errors()
  end

  defp load_recent_errors(socket) do
    since = DateTime.utc_now() |> DateTime.add(-@error_window_hours * 3600, :second)

    errors =
      from(rl in RequestLog,
        where: rl.status_code >= 400 and rl.inserted_at >= ^since,
        order_by: [desc: rl.inserted_at],
        limit: ^@error_limit
      )
      |> Repo.all()

    assign(socket, :recent_errors, errors)
  end

  ## Helpers ---------------------------------------------------------------

  defp fmt_dt(nil), do: "—"

  defp fmt_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%d/%m/%Y %H:%M UTC")
  end

  defp breaker_label(:closed), do: "Cerrado"
  defp breaker_label(:open), do: "Abierto"
  defp breaker_label(:half_open), do: "Half-Open"
  defp breaker_label(_), do: "—"

  defp status_class_for(status_code) when status_code >= 500, do: "badge-error"
  defp status_class_for(status_code) when status_code >= 400, do: "badge-warning"
  defp status_class_for(_), do: "badge-ghost"

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
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
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
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
          :if={@error_credentials == [] and @breaker_alerts == [] and @recent_errors == []}
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
                      <th>Razón</th>
                      <th>Cuándo</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={cred <- @error_credentials} id={"alert-cred-#{cred.id}"}>
                      <td class="font-medium">{cred.provider.name}</td>
                      <td>{cred.name || "—"}</td>
                      <td>
                        <code class="text-xs text-error">{cred.error_reason || "auth_error"}</code>
                      </td>
                      <td class="text-xs text-base-content/50">{fmt_dt(cred.error_at)}</td>
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
                      <th>Estado</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{cred, status} <- @breaker_alerts} id={"alert-breaker-#{cred.id}"}>
                      <td class="font-medium">{cred.provider.name}</td>
                      <td>{cred.name || "—"}</td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          status == :open && "badge-error",
                          status == :half_open && "badge-warning"
                        ]}>
                          {breaker_label(status)}
                        </span>
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
                      <th>Agente</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={log <- @recent_errors} id={"alert-error-#{log.id}"}>
                      <td class="whitespace-nowrap text-sm">{fmt_dt(log.inserted_at)}</td>
                      <td>
                        <span class={["badge badge-sm", status_class_for(log.status_code)]}>
                          {log.status_code}
                        </span>
                      </td>
                      <td class="text-sm">{log.model_requested}</td>
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
