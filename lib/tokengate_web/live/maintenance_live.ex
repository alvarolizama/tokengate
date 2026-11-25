defmodule TokengateWeb.MaintenanceLive do
  @moduledoc """
  Admin maintenance page — read-only config overview plus Danger Zone actions.

  Currently supports:
    * Leave everything at zero (usage: logs, metrics and counters, plus unused
      catalog records and sticky routes)
    * Reset sticky sessions

  El **presupuesto mensual** de cada sujeto y sus top-ups viven en la sección
  Presupuesto (`/budget/profiles`, `/budget/topups`); esta página solo muestra
  el gasto del día y las acciones de limpieza.
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
      |> assign(:confirm_purge, false)
      |> assign(:purge_preview, nil)
      |> assign(:purge_retention_days, Tokengate.Logs.PartitionWorker.retention_days())
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
      "all",
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

  # Purga manual de historia: el preview se calcula AL ABRIR el modal (no en
  # mount) para no pagar sus conteos en cada carga de la página, y el operador
  # confirma viendo números: fecha de corte, particiones, filas estimadas.
  @impl true
  def handle_event("show_purge_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:purge_preview, Tokengate.Logs.Retention.preview())
     |> assign(:confirm_purge, true)}
  end

  def handle_event("cancel_purge", _params, socket) do
    {:noreply, socket |> assign(:confirm_purge, false) |> assign(:purge_preview, nil)}
  end

  # Borra la historia que ya pasó la retención (la MISMA ventana que el cron
  # diario) y audita con los conteos reales. No toca contadores de consumo,
  # presupuestos del mes, usuarios, keys, catálogo ni audit_logs: sólo los logs
  # crudos vencidos, sus filas varadas en la partición default y el rollup de
  # esos mismos días (simétrico, o las lecturas híbridas leerían ceros).
  def handle_event("purge_expired", _params, socket) do
    {:ok, result} = Tokengate.Logs.Retention.purge()

    # `entity_id` is required by the audit changeset: passing nil here (as the
    # reset below used to) made `Auditing.log` return an invalid changeset and
    # the audit row was silently LOST. "history" is the stable label for this
    # whole-table action.
    Tokengate.Auditing.log(
      socket.assigns.current_user,
      "settings.purge_expired_logs",
      "usage",
      "history",
      %{
        "cutoff_day" => Date.to_iso8601(result.cutoff_day),
        "retention_days" => result.retention_days,
        "partitions_dropped" => result.partitions_dropped,
        "default_deleted" => result.default[:deleted] || 0,
        "rollup_deleted" => result.rollup[:deleted] || 0
      }
    )

    {:noreply,
     socket
     |> assign(:confirm_purge, false)
     |> assign(:purge_preview, nil)
     |> put_flash(
       :info,
       gettext(
         "Purged %{partitions} partition(s) and %{rows} rollup row(s) older than %{date}.",
         partitions: length(result.partitions_dropped),
         rows: result.rollup[:deleted] || 0,
         date: Date.to_iso8601(result.cutoff_day)
       )
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
      "all"
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
          "global"
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

            <div class="divider my-2"></div>

            <%!-- Purga de historia vencida: la MISMA ventana que el cron diario
                 (90 días por default), a demanda. No es un reset: no toca
                 usuarios, keys, catálogo, presupuestos del mes ni contadores de
                 consumo — sólo los logs viejos, sus filas varadas en la
                 partición default y el rollup de esos días. --%>
            <div class="flex items-center justify-between gap-4">
              <div>
                <h3 class="font-semibold text-base-content">
                  {gettext("Purge history past the retention window")}
                </h3>
                <p class="text-sm text-base-content/60">
                  {gettext(
                    "Deletes the raw request logs older than the retention window (%{days} days, set by the nightly job's policy), the expired rows ever stranded in the default partition, and the hourly rollup of those same days.",
                    days: @purge_retention_days
                  )}
                  {gettext(
                    "Keeps users, services, API keys, the month's budgets, the durable consumption counters and audit logs."
                  )}
                </p>
              </div>
              <button
                type="button"
                phx-click="show_purge_confirm"
                class="btn btn-error btn-outline btn-sm"
                id="purge-expired-btn"
              >
                {gettext("Purge history")}
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Confirmación de purga: muestra el corte y los números ANTES de borrar --%>
      <.modal
        :if={@confirm_purge and @purge_preview}
        id="confirm-purge-modal"
        title={gettext("Purge history past the retention window?")}
        on_close="cancel_purge"
        max_w="max-w-lg"
      >
        <div class="flex items-start gap-2 text-sm text-base-content/70">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-error shrink-0" />
          <div class="space-y-3">
            <p>
              {gettext("Deletes")} <strong>{gettext("permanently")}</strong>
              {gettext("everything older than")}
              <span class="font-mono" id="purge-cutoff">
                {@purge_preview.cutoff_day |> Date.to_iso8601()}
              </span>
              {gettext("(the retention window, %{days} days):",
                days: @purge_preview.retention_days
              )}
            </p>

            <ul class="list-disc pl-5 space-y-1" id="purge-preview">
              <li>
                <span class="font-mono">{@purge_preview.partition_count}</span>
                {gettext("expired daily partition(s)")}
                <%= if @purge_preview.partition_count > 0 do %>
                  <span class="text-base-content/50">
                    ({@purge_preview.partitions |> Enum.map(& &1.name) |> Enum.join(", ")})
                  </span>
                <% end %>
              </li>
              <li>
                <span class="font-mono">~{@purge_preview.rows_estimate}</span>
                {gettext("rows (partition estimate)")}
              </li>
              <li>
                <span class="font-mono">{@purge_preview.default_expired_rows}</span>
                {gettext("expired rows stranded in the default partition")}
              </li>
              <li>
                <span class="font-mono">{@purge_preview.rollup_rows}</span>
                {gettext("hourly rollup rows of those days (purged together on purpose)")}
              </li>
            </ul>

            <p>
              {gettext(
                "It cannot be recovered. Budget enforcement, the durable consumption counters and audit logs are NOT touched."
              )}
            </p>
          </div>
        </div>
        <:footer>
          <button type="button" phx-click="cancel_purge" class="btn btn-ghost btn-sm">
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            phx-click="purge_expired"
            class="btn btn-error btn-sm"
            id="confirm-purge-btn"
            disabled={
              @purge_preview.partition_count == 0 and
                @purge_preview.default_expired_rows == 0 and @purge_preview.rollup_rows == 0
            }
          >
            {gettext("Yes, purge expired history")}
          </button>
        </:footer>
      </.modal>

      <%!-- Confirmation modal: full reset (usage + unused catalog) --%>
      <.modal
        :if={@confirm_full_reset}
        id="confirm-full-reset-modal"
        title={gettext("Leave everything at zero?")}
        on_close="cancel_full_reset"
        max_w="max-w-md"
      >
        <div class="flex items-start gap-2 text-sm text-base-content/70">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-error shrink-0" />
          <div class="space-y-2">
            <p>
              {gettext("Deletes")} <strong>{gettext("permanently")}</strong>
              {gettext(
                "all usage history (logs, hourly metrics, budget counters, sticky routes) AND catalog records with no deployment: models without deployments and providers without credentials."
              )}
              {gettext("They cannot be recovered.")}
            </p>
            <p>
              {gettext(
                "Users, services, API keys, limit profiles, models with deployments and providers with credentials are kept."
              )}
            </p>
          </div>
        </div>
        <:footer>
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
        </:footer>
      </.modal>

      <%!-- Confirmation modal: reset sticky sessions --%>
      <.modal
        :if={@confirm_sticky_reset}
        id="confirm-sticky-reset-modal"
        title={gettext("Reset sticky sessions?")}
        on_close="cancel_sticky_reset"
        max_w="max-w-md"
      >
        <div class="flex items-start gap-2 text-sm text-base-content/70">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-warning shrink-0" />
          <div class="space-y-2">
            <p>
              {gettext("This deletes")}
              <strong>{gettext("all")}</strong> {gettext("API key to provider assignments.")}
              {gettext("The next requests will be re-routed from scratch,")}
              {gettext("without preserving the cache affinity.")}
            </p>
            <p>
              {gettext("Models, providers and API keys are not affected.")}
            </p>
          </div>
        </div>
        <:footer>
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
        </:footer>
      </.modal>
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
