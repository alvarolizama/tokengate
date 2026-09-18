defmodule TokengateWeb.MaintenanceLive do
  @moduledoc """
  Admin maintenance page — read-only config overview plus Danger Zone actions.

  Currently supports:
    * Reset all request logs (truncate `request_logs` table)
    * Reset sticky sessions

  El **tope diario global** y sus exclusiones NO viven aquí: son una palanca de
  presupuesto y se mudaron a `/budget/global` (`TokengateWeb.GlobalCapLive`).
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Logs
  alias Tokengate.Providers
  alias Tokengate.Providers.CatalogRefreshWorker
  alias Tokengate.Repo
  alias Tokengate.Routing.StickyTracker

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, CatalogRefreshWorker.topic())
    end

    socket =
      socket
      |> assign(:page_title, "Mantenimiento · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:confirm_reset, false)
      |> assign(:confirm_sticky_reset, false)
      |> assign(:log_count, count_logs())
      |> assign(:sticky_count, sticky_count())
      |> assign_catalog()
      |> require_admin_hook()

    {:ok, socket}
  end

  # Catalog state for the "models.dev" card: last refresh outcome (including
  # base-URL drift warnings) and whether one is queued/running.
  defp assign_catalog(socket) do
    state = Providers.catalog_sync_state()

    socket
    |> assign(:catalog_state, state)
    |> assign(:catalog_warnings, (state && state.warnings) || [])
    |> assign(:catalog_refreshing, Providers.catalog_refresh_in_flight?())
    |> assign(:catalog_active_count, Providers.count_catalog_providers("active"))
    |> assign(:catalog_stale_count, Providers.count_catalog_providers("stale"))
    |> assign(:lab_active_count, Providers.count_labs("active"))
    |> assign(:model_active_count, Providers.count_catalog_models("active"))
    |> assign(:model_stale_count, Providers.count_catalog_models("stale"))
    |> assign(:offer_count, Providers.count_catalog_offers())
  end

  defp fmt_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

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

    Tokengate.Auditing.audit(
      socket.assigns.current_user,
      "settings.reset_logs",
      "request_logs",
      nil
    )

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

    Tokengate.Auditing.audit(
      socket.assigns.current_user,
      "settings.reset_sticky_sessions",
      "sticky_sessions",
      nil
    )

    {:noreply,
     socket
     |> assign(:confirm_sticky_reset, false)
     |> assign(:sticky_count, 0)
     |> put_flash(:info, "Sticky sessions reiniciadas.")}
  end

  # Enqueues the models.dev refresh. The download and the mirror upsert run in
  # Oban (with retries), so the page only flips the button to its busy state;
  # the worker broadcasts when it finishes and the card re-renders with the
  # outcome.
  @impl true
  def handle_event("refresh_catalog", _params, socket) do
    case Providers.request_catalog_refresh() do
      {:ok, _job} ->
        Tokengate.Auditing.audit(
          socket.assigns.current_user,
          "settings.catalog_refresh",
          "catalog_providers",
          nil
        )

        {:noreply,
         socket
         |> assign(:catalog_refreshing, true)
         |> put_flash(:info, "Actualización del catálogo encolada.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo encolar la actualización.")}
    end
  end

  ## Catalog refresh notifications ------------------------------------------

  @impl true
  def handle_info({:catalog_refresh_done}, socket) do
    {:noreply,
     socket
     |> assign_catalog()
     |> put_flash(:info, "Catálogo de proveedores actualizado.")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="max-w-3xl mx-auto space-y-8">
        <div>
          <h1 class="text-2xl font-bold text-base-content">Mantenimiento</h1>
          <p class="text-sm text-base-content/60 mt-1">
            Administra configuraciones avanzadas y acciones destructivas.
          </p>
        </div>

        <%!-- Zona de precaución: acciones repetibles o reversibles --%>
        <div class="card bg-base-100 border border-warning/30" id="caution-zone-card">
          <div class="card-body">
            <h2 class="card-title text-warning flex items-center gap-2">
              <.icon name="hero-shield-exclamation" class="w-5 h-5" /> Zona de precaución
            </h2>
            <p class="text-sm text-base-content/60">
              Acciones repetibles o reversibles: no borran datos de forma permanente.
              Revisa el alcance de cada una antes de ejecutarla.
            </p>

            <div class="divider my-2"></div>

            <div class="flex items-center justify-between">
              <div>
                <h3 class="font-semibold text-base-content">Reiniciar sticky sessions</h3>
                <p class="text-sm text-base-content/60">
                  Borra todas las asignaciones sticky de API key → provider.
                  Las próximas requests serán re-ruteadas desde cero.
                  No afecta models, proveedores, ni API keys.
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

            <%!-- External data, not user data: the refresh upserts the mirror
                 from models.dev and re-materializes provider identity. Nothing
                 is deleted, so it belongs in the caution zone. --%>
            <div class="flex items-start justify-between gap-4" id="catalog-refresh-card">
              <div>
                <h3 class="font-semibold text-base-content">Catálogo de models.dev</h3>
                <p class="text-sm text-base-content/60">
                  Vuelve a bajar el catálogo (proveedores, labs y modelos) y actualiza nombre, base URL,
                  docs y logo de los builtins. No toca credenciales, modelos propios, routing ni
                  proveedores custom, y no borra nada: lo que ya no está upstream se marca como obsoleto.
                  <span :if={@catalog_state && @catalog_state.synced_at}>
                    Última actualización:
                    <span class="font-mono">{fmt_dt(@catalog_state.synced_at)}</span>
                    ({@catalog_state.source || "—"}).
                  </span>
                  <span :if={@catalog_state && @catalog_state.error} class="text-error">
                    Último intento falló: {@catalog_state.error}
                  </span>
                </p>

                <ul
                  :if={@catalog_warnings != []}
                  class="text-xs text-warning mt-1 space-y-0.5"
                  id="catalog-drift-warnings"
                >
                  <li :for={warning <- @catalog_warnings}>
                    <span :if={warning["reason"] == "base_url_changed"}>
                      <span class="font-mono">{warning["key"]}</span>
                      cambió su base URL ({warning["from"]} → {warning["to"]}) y tiene
                      <span class="font-mono">{warning["credentials"]}</span>
                      credencial(es) en uso.
                    </span>
                    <span :if={warning["reason"] == "already_stale"}>
                      <span class="font-mono">{warning["key"]}</span>
                      ya no aparece en models.dev y tiene
                      <span class="font-mono">{warning["credentials"]}</span>
                      credencial(es) en uso (no se ha borrado nada).
                    </span>
                    <span :if={warning["reason"] == "empty_model_mirror"}>
                      El catálogo de <span class="font-mono">modelos</span> estaba vacío al
                      arrancar (el snapshot vendorizado no se pudo leer): se encoló una
                      actualización automática contra models.dev.
                    </span>
                  </li>
                </ul>

                <p class="text-xs text-base-content/40 mt-1">
                  Proveedores: <span class="font-mono">{@catalog_active_count}</span>
                  activos, <span class="font-mono">{@catalog_stale_count}</span>
                  obsoletos · Labs: <span class="font-mono">{@lab_active_count}</span>
                  ·
                  Modelos: <span class="font-mono">{@model_active_count}</span>
                  (<span class="font-mono">{@model_stale_count}</span>
                  obsoletos), <span class="font-mono">{@offer_count}</span>
                  ofertas.
                </p>
              </div>

              <button
                type="button"
                phx-click="refresh_catalog"
                class="btn btn-warning btn-outline btn-sm shrink-0"
                id="refresh-catalog-btn"
                disabled={@catalog_refreshing}
              >
                {if @catalog_refreshing, do: "Actualizando…", else: "Actualizar ahora"}
              </button>
            </div>
          </div>
        </div>

        <%!-- Zona de peligro: acciones irreversibles, siempre al final de la página --%>
        <div class="card bg-base-100 border border-error/30" id="danger-zone-card">
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
                  No afecta usuarios, perfiles de límites, models, proveedores ni API keys.
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
              Usuarios, perfiles de límites, models, proveedores y API keys no se ven afectados.
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
end
