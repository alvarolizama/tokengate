defmodule TokengateWeb.MaintenanceLive do
  @moduledoc """
  Admin maintenance page — read-only config overview plus Danger Zone actions.

  Currently supports:
    * Leave everything at zero (usage: logs, metrics and counters, plus unused
      catalog records and sticky routes)
    * Reset sticky sessions

  El **tope diario global** y sus exclusiones NO viven aquí: son una palanca de
  presupuesto y se mudaron a `/budget/global` (`TokengateWeb.GlobalCapLive`).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Logs
  alias Tokengate.Providers
  alias Tokengate.Providers.CatalogRefreshWorker
  alias Tokengate.Routing.StickyTracker

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, CatalogRefreshWorker.topic())
    end

    socket =
      socket
      |> assign(:page_title, gettext("Maintenance") <> " · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:confirm_full_reset, false)
      |> assign(:confirm_sticky_reset, false)
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

  # "Dejar todo en cero": reset de uso + purga de registros del catálogo sin
  # despliegue/credencial. Conserva usuarios, servicios, API keys, modelos
  # con despliegue y proveedores con credencial.
  @impl true
  def handle_event("reset_all_usage", _params, socket) do
    Logs.truncate_request_logs()
    purged = Providers.purge_unused_catalog()
    StickyTracker.clear_all()

    Tokengate.Auditing.audit(
      socket.assigns.current_user,
      "settings.reset_all_usage",
      "usage",
      nil,
      %{"models_purged" => purged.models, "providers_purged" => purged.providers}
    )

    {:noreply,
     socket
     |> assign(:confirm_full_reset, false)
     |> assign(:sticky_count, 0)
     |> put_flash(
       :info,
       "Uso reseteado: logs y métricas a cero, #{purged.models} modelo(s) y " <>
         "#{purged.providers} proveedor(es) sin uso eliminados, rutas sticky liberadas."
     )}
  end

  @impl true
  def handle_event("show_sticky_reset_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_sticky_reset, true)}
  end

  @impl true
  def handle_event("show_full_reset_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_full_reset, true)}
  end

  @impl true
  def handle_event("cancel_full_reset", _params, socket) do
    {:noreply, assign(socket, :confirm_full_reset, false)}
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
         |> put_flash(:info, gettext("Catalog refresh queued."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not queue the refresh."))}
    end
  end

  ## Catalog refresh notifications ------------------------------------------

  @impl true
  def handle_info({:catalog_refresh_done}, socket) do
    {:noreply,
     socket
     |> assign_catalog()
     |> put_flash(:info, gettext("Provider catalog updated."))}
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
          <h1 class="text-2xl font-bold text-base-content">{gettext("Maintenance")}</h1>
          <p class="text-sm text-base-content/60 mt-1">
            {gettext("Manage advanced settings and destructive actions.")}
          </p>
        </div>

        <%!-- Zona de precaución: acciones repetibles o reversibles --%>
        <div class="card bg-base-100 border border-warning/30" id="caution-zone-card">
          <div class="card-body">
            <h2 class="card-title text-warning flex items-center gap-2">
              <.icon name="hero-shield-exclamation" class="w-5 h-5" /> {gettext("Caution zone")}
            </h2>
            <p class="text-sm text-base-content/60">
              {gettext("Repeatable or reversible actions: they do not erase data permanently.")}
              {gettext("Review the scope of each one before running it.")}
            </p>

            <div class="divider my-2"></div>

            <div class="flex items-center justify-between">
              <div>
                <h3 class="font-semibold text-base-content">{gettext("Reset sticky sessions")}</h3>
                <p class="text-sm text-base-content/60">
                  {gettext("Deletes every sticky API key → provider assignment.")}
                  {gettext("The next requests will be re-routed from scratch.")}
                  {gettext("It does not touch models, providers or API keys.")}
                  {gettext("There are currently")}
                  <span class="font-mono font-semibold">{@sticky_count}</span>
                  {gettext("active entries.")}
                </p>
              </div>
              <button
                type="button"
                phx-click="show_sticky_reset_confirm"
                class="btn btn-warning btn-outline btn-sm"
                id="reset-sticky-btn"
              >
                {gettext("Reset stickies")}
              </button>
            </div>

            <div class="divider my-2"></div>

            <%!-- External data, not user data: the refresh upserts the mirror
                 from models.dev and re-materializes provider identity. Nothing
                 is deleted, so it belongs in the caution zone. --%>
            <div class="flex items-start justify-between gap-4" id="catalog-refresh-card">
              <div>
                <h3 class="font-semibold text-base-content">{gettext("models.dev catalog")}</h3>
                <p class="text-sm text-base-content/60">
                  {gettext(
                    "Downloads the catalog again (providers and labs) and updates name, base URL,"
                  )}
                  {gettext(
                    "docs and logo of the builtins. It does not touch credentials, own models, routing or"
                  )}
                  {gettext(
                    "custom providers, and deletes nothing: what is no longer upstream is marked as stale."
                  )}
                  <span :if={@catalog_state && @catalog_state.synced_at}>
                    {gettext("Last update:")}
                    <span class="font-mono">{fmt_dt(@catalog_state.synced_at)}</span>
                    ({@catalog_state.source || "—"}).
                  </span>
                  <span :if={@catalog_state && @catalog_state.error} class="text-error">
                    {gettext("Last attempt failed:")} {@catalog_state.error}
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
                      {gettext("changed its base URL")} ({warning["from"]} → {warning["to"]}) {gettext(
                        "and has"
                      )}
                      <span class="font-mono">{warning["credentials"]}</span>
                      {gettext("credential(s) in use.")}
                    </span>
                    <span :if={warning["reason"] == "already_stale"}>
                      <span class="font-mono">{warning["key"]}</span>
                      {gettext("no longer appears in models.dev and has")}
                      <span class="font-mono">{warning["credentials"]}</span>
                      {gettext("credential(s) in use (nothing has been deleted).")}
                    </span>
                  </li>
                </ul>

                <p class="text-xs text-base-content/40 mt-1">
                  {gettext("Providers:")} <span class="font-mono">{@catalog_active_count}</span>
                  {gettext("active,")} <span class="font-mono">{@catalog_stale_count}</span>
                  {gettext("stale · Labs:")} <span class="font-mono">{@lab_active_count}</span>
                </p>
              </div>

              <button
                type="button"
                phx-click="refresh_catalog"
                class="btn btn-warning btn-outline btn-sm shrink-0"
                id="refresh-catalog-btn"
                disabled={@catalog_refreshing}
              >
                {if @catalog_refreshing,
                  do: gettext("Refreshing…"),
                  else: gettext("Refresh now")}
              </button>
            </div>
          </div>
        </div>

        <%!-- Zona de peligro: acciones irreversibles, siempre al final de la página --%>
        <div class="card bg-base-100 border border-error/30" id="danger-zone-card">
          <div class="card-body">
            <h2 class="card-title text-error flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> {gettext("Danger zone")}
            </h2>
            <p class="text-sm text-base-content/60">
              {gettext("The actions in this section are irreversible. Use them with caution.")}
            </p>

            <div class="divider my-2"></div>

            <%!-- Reset total: uso + registros de catálogo sin uso --%>
            <div class="flex items-center justify-between gap-4">
              <div>
                <h3 class="font-semibold text-base-content">
                  {gettext("Leave everything at zero")}
                </h3>
                <p class="text-sm text-base-content/60">
                  {gettext(
                    "Deletes all usage history (logs, hourly metrics, budget counters and sticky routes), plus catalog records with no deployment: models without deployments and providers without credentials or deployments."
                  )}
                  {gettext(
                    "Keeps users, services, API keys, limit profiles, models with deployments and providers with credentials."
                  )}
                </p>
              </div>
              <button
                type="button"
                phx-click="show_full_reset_confirm"
                class="btn btn-error btn-outline btn-sm"
                id="reset-all-usage-btn"
              >
                {gettext("Full reset")}
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Confirmation modal: full reset (usage + unused catalog) --%>
      <div :if={@confirm_full_reset} class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/50" phx-click="cancel_full_reset" />
        <div class="relative card bg-base-100 border border-error/50 shadow-xl w-full max-w-md">
          <div class="card-body">
            <h3 class="card-title text-error flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              {gettext("Leave everything at zero?")}
            </h3>
            <p class="text-sm text-base-content/70 mt-2">
              {gettext("Deletes")} <strong>{gettext("permanently")}</strong>
              {gettext(
                "all usage history (logs, hourly metrics, budget counters, sticky routes) AND catalog records with no deployment: models without deployments and providers without credentials."
              )}
              {gettext("They cannot be recovered.")}
            </p>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Users, services, API keys, limit profiles, models with deployments and providers with credentials are kept."
              )}
            </p>
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_full_reset" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
              <button
                type="button"
                phx-click="reset_all_usage"
                class="btn btn-error btn-sm"
                id="confirm-reset-all-usage-btn"
              >
                {gettext("Yes, leave everything at zero")}
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
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> {gettext(
                "Reset sticky sessions?"
              )}
            </h3>
            <p class="text-sm text-base-content/70 mt-2">
              {gettext("This deletes")}
              <strong>{gettext("all")}</strong> {gettext("API key to provider assignments.")}
              {gettext("The next requests will be re-routed from scratch,")}
              {gettext("without preserving the cache affinity.")}
            </p>
            <p class="text-sm text-base-content/70">
              {gettext("Models, providers and API keys are not affected.")}
            </p>
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_sticky_reset" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
              <button
                type="button"
                phx-click="reset_sticky_sessions"
                class="btn btn-warning btn-sm"
                id="confirm-reset-sticky-btn"
              >
                {gettext("Yes, reset stickies")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Helpers ----------------------------------------------------------------

  defp sticky_count do
    try do
      :ets.info(:tokengate_sticky_routes, :size) || 0
    rescue
      ArgumentError -> 0
    end
  end
end
