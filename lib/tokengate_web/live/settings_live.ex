defmodule TokengateWeb.SettingsLive do
  @moduledoc """
  Admin settings page — read-only config overview plus Danger Zone actions.

  Currently supports:
    * Reset all request logs (truncate `request_logs` table)
    * Reset sticky sessions
    * Reset all member extras (budget, concurrency, rpm)
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Logs
  alias Tokengate.Repo
  alias Tokengate.Routing.StickyTracker

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Configuración · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:confirm_reset, false)
      |> assign(:confirm_sticky_reset, false)
      |> assign(:confirm_extras_reset, false)
      |> assign(:log_count, count_logs())
      |> assign(:sticky_count, sticky_count())
      |> assign(:extras_count, count_members_with_extras())
      |> require_admin_hook()

    {:ok, socket}
  end

  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  ## Events -----------------------------------------------------------------

  @impl true
  def handle_event("show_reset_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_reset, true)}
  end

  @impl true
  def handle_event("cancel_reset", _params, socket) do
    {:noreply, assign(socket, :confirm_reset, false)}
  end

  @impl true
  def handle_event("reset_logs", _params, socket) do
    Logs.truncate_request_logs()

    {:noreply,
     socket
     |> assign(:confirm_reset, false)
     |> assign(:log_count, 0)
     |> put_flash(:info, "Historial de logs eliminado.")}
  end

  @impl true
  def handle_event("show_sticky_reset_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_sticky_reset, true)}
  end

  @impl true
  def handle_event("cancel_sticky_reset", _params, socket) do
    {:noreply, assign(socket, :confirm_sticky_reset, false)}
  end

  @impl true
  def handle_event("reset_sticky_sessions", _params, socket) do
    StickyTracker.clear_all()

    {:noreply,
     socket
     |> assign(:confirm_sticky_reset, false)
     |> assign(:sticky_count, 0)
     |> put_flash(:info, "Sticky sessions reiniciadas.")}
  end

  @impl true
  def handle_event("show_extras_reset_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_extras_reset, true)}
  end

  @impl true
  def handle_event("cancel_extras_reset", _params, socket) do
    {:noreply, assign(socket, :confirm_extras_reset, false)}
  end

  @impl true
  def handle_event("reset_all_extras", _params, socket) do
    count = reset_all_member_extras()

    {:noreply,
     socket
     |> assign(:confirm_extras_reset, false)
     |> assign(:extras_count, 0)
     |> put_flash(:info, "Extras de #{count} miembros reiniciados.")}
  end

  ## Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="max-w-3xl mx-auto space-y-8">
        <div>
          <h1 class="text-2xl font-bold text-base-content">Configuración</h1>
          <p class="text-sm text-base-content/60 mt-1">
            Administra configuraciones avanzadas y acciones destructivas.
          </p>
        </div>

        <%!-- Danger Zone --%>
        <div class="card bg-base-100 border border-error/30">
          <div class="card-body">
            <h2 class="card-title text-error flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> Zona de peligro
            </h2>
            <p class="text-sm text-base-content/60">
              Las acciones en esta sección son irreversibles. Úsalas con precaución.
            </p>

            <div class="divider my-2"></div>

            <div class="flex items-center justify-between">
              <div>
                <h3 class="font-semibold text-base-content">Eliminar historial de logs</h3>
                <p class="text-sm text-base-content/60">
                  Borra todas las filas de <code>request_logs</code>.
                  No afecta usuarios, equipos, modelos, proveedores ni API keys.
                  Actualmente hay <span class="font-mono font-semibold">{@log_count}</span> registros.
                </p>
              </div>
              <button
                type="button"
                phx-click="show_reset_confirm"
                class="btn btn-error btn-outline btn-sm"
                id="reset-logs-btn"
              >
                Eliminar logs
              </button>
            </div>

            <div class="divider my-2"></div>

            <div class="flex items-center justify-between">
              <div>
                <h3 class="font-semibold text-base-content">Reiniciar sticky sessions</h3>
                <p class="text-sm text-base-content/60">
                  Borra todas las asignaciones sticky de API key → provider.
                  Las próximas requests serán re-ruteadas desde cero.
                  No afecta modelos, proveedores, ni API keys.
                  Actualmente hay <span class="font-mono font-semibold">{@sticky_count}</span>
                  entradas activas.
                </p>
              </div>
              <button
                type="button"
                phx-click="show_sticky_reset_confirm"
                class="btn btn-warning btn-outline btn-sm"
                id="reset-sticky-btn"
              >
                Reiniciar stickies
              </button>
            </div>

            <div class="divider my-2"></div>

            <div class="flex items-center justify-between">
              <div>
                <h3 class="font-semibold text-base-content">Reiniciar extras de miembros</h3>
                <p class="text-sm text-base-content/60">
                  Elimina todos los <code>extra_monthly_budget_usd</code>,
                  <code>extra_concurrency</code> y <code>extra_rpm</code>
                  de todos los miembros de todos los equipos.
                  Los miembros quedarán con los valores por defecto de su equipo.
                  El gasto acumulado NO se resetea.
                  Actualmente hay <span class="font-mono font-semibold">{@extras_count}</span>
                  miembros con extras activos.
                </p>
              </div>
              <button
                type="button"
                phx-click="show_extras_reset_confirm"
                class="btn btn-warning btn-outline btn-sm"
                id="reset-extras-btn"
              >
                Reiniciar extras
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Confirmation modal: reset logs --%>
      <div :if={@confirm_reset} class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/50" phx-click="cancel_reset" />
        <div class="relative card bg-base-100 border border-error/50 shadow-xl w-full max-w-md">
          <div class="card-body">
            <h3 class="card-title text-error flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> ¿Eliminar todo el historial?
            </h3>
            <p class="text-sm text-base-content/70 mt-2">
              Esta acción borra <strong>permanentemente</strong>
              todos los registros de <code>request_logs</code>. No se pueden recuperar.
            </p>
            <p class="text-sm text-base-content/70">
              Usuarios, equipos, modelos, proveedores y API keys no se ven afectados.
            </p>
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_reset" class="btn btn-ghost btn-sm">
                Cancelar
              </button>
              <button
                type="button"
                phx-click="reset_logs"
                class="btn btn-error btn-sm"
                id="confirm-reset-logs-btn"
              >
                Sí, eliminar todo
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Confirmation modal: reset sticky sessions --%>
      <div :if={@confirm_sticky_reset} class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/50" phx-click="cancel_sticky_reset" />
        <div class="relative card bg-base-100 border border-warning/50 shadow-xl w-full max-w-md">
          <div class="card-body">
            <h3 class="card-title text-warning flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> ¿Reiniciar sticky sessions?
            </h3>
            <p class="text-sm text-base-content/70 mt-2">
              Esto borra <strong>todas</strong> las asignaciones de API key a provider.
              Las próximas requests serán re-ruteadas desde cero,
              sin preservar la afinidad de cache.
            </p>
            <p class="text-sm text-base-content/70">
              Modelos, proveedores y API keys no se ven afectados.
            </p>
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_sticky_reset" class="btn btn-ghost btn-sm">
                Cancelar
              </button>
              <button
                type="button"
                phx-click="reset_sticky_sessions"
                class="btn btn-warning btn-sm"
                id="confirm-reset-sticky-btn"
              >
                Sí, reiniciar stickies
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Confirmation modal: reset member extras --%>
      <div :if={@confirm_extras_reset} class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/50" phx-click="cancel_extras_reset" />
        <div class="relative card bg-base-100 border border-warning/50 shadow-xl w-full max-w-md">
          <div class="card-body">
            <h3 class="card-title text-warning flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> ¿Reiniciar extras de miembros?
            </h3>
            <p class="text-sm text-base-content/70 mt-2">
              Esto eliminará <strong>todos</strong> los extras de todos los miembros:
            </p>
            <ul class="text-sm text-base-content/70 list-disc list-inside mt-1">
              <li><code>extra_monthly_budget_usd</code> → nil</li>
              <li><code>extra_concurrency</code> → nil</li>
              <li><code>extra_rpm</code> → nil</li>
            </ul>
            <p class="text-sm text-base-content/70 mt-2">
              Cada miembro quedarán con los valores por defecto de su equipo.
              El gasto acumulado <strong>no se resetea</strong>.
            </p>
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_extras_reset" class="btn btn-ghost btn-sm">
                Cancelar
              </button>
              <button
                type="button"
                phx-click="reset_all_extras"
                class="btn btn-warning btn-sm"
                id="confirm-reset-extras-btn"
              >
                Sí, reiniciar extras
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Helpers ----------------------------------------------------------------

  defp count_logs do
    import Ecto.Query
    Repo.one(from(rl in Tokengate.Logs.RequestLog, select: count(rl.id)))
  end

  defp sticky_count do
    try do
      :ets.info(:tokengate_sticky_routes, :size) || 0
    rescue
      ArgumentError -> 0
    end
  end

  defp count_members_with_extras do
    import Ecto.Query

    Repo.one(
      from(tm in "team_members",
        where:
          not is_nil(tm.extra_monthly_budget_usd) or
            not is_nil(tm.extra_concurrency) or
            not is_nil(tm.extra_rpm),
        select: count(tm.id)
      )
    )
  end

  defp reset_all_member_extras do
    import Ecto.Query

    {count, _} =
      Repo.update_all(
        from(tm in "team_members",
          where:
            not is_nil(tm.extra_monthly_budget_usd) or
              not is_nil(tm.extra_concurrency) or
              not is_nil(tm.extra_rpm)
        ),
        set: [
          extra_monthly_budget_usd: nil,
          extra_concurrency: nil,
          extra_rpm: nil,
          updated_at: DateTime.truncate(DateTime.utc_now(), :second)
        ]
      )

    count
  end
end
