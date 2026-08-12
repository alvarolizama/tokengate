defmodule TokengateWeb.SettingsLive do
  @moduledoc """
  Admin settings page — read-only config overview plus Danger Zone actions.

  Currently supports:
    * Reset all request logs (truncate `request_logs` table)
    * Reset sticky sessions
    * Reset per-field member extras (budget, concurrency, rpm)
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Logs
  alias Tokengate.Logs.CostBackfill
  alias Tokengate.Repo
  alias Tokengate.GlobalSettings
  alias Tokengate.Routing.StickyTracker
  alias Tokengate.Budgets.Manager, as: Budgets

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Configuración · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:confirm_reset, false)
      |> assign(:confirm_sticky_reset, false)
      |> assign(:extras_reset_type, nil)
      |> assign(:confirm_backfill, false)
      |> assign(:backfill_running, false)
      |> assign(:backfill_count, CostBackfill.count_eligible())
      |> assign(:log_count, count_logs())
      |> assign(:sticky_count, sticky_count())
      |> assign(:extras_budget_count, count_members_with_extra(:extra_monthly_budget_usd))
      |> assign(:extras_concurrency_count, count_members_with_extra(:extra_concurrency))
      |> assign(:extras_rpm_count, count_members_with_extra(:extra_rpm))
      |> assign_global_settings()
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
  def handle_event("save_global_cap", %{"global_settings" => params}, socket) do
    case GlobalSettings.update(params) do
      {:ok, _settings} ->
        Tokengate.Auditing.audit(
          socket.assigns.current_user,
          "settings.update_global_daily_cap",
          "global_settings",
          nil,
          params
        )

        {:noreply,
         socket
         |> assign_global_settings()
         |> put_flash(:info, "Límite diario global actualizado.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :global_form, to_form(changeset, as: :global_settings))}
    end
  end

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

  @impl true
  def handle_event("show_extras_reset_confirm", %{"field" => field}, socket)
      when field in ["extra_monthly_budget_usd", "extra_concurrency", "extra_rpm"] do
    {:noreply, assign(socket, :extras_reset_type, String.to_existing_atom(field))}
  end

  @impl true
  def handle_event("cancel_extras_reset", _params, socket) do
    {:noreply, assign(socket, :extras_reset_type, nil)}
  end

  @impl true
  def handle_event("reset_extra", %{"field" => field}, socket)
      when field in ["extra_monthly_budget_usd", "extra_concurrency", "extra_rpm"] do
    field_atom = String.to_existing_atom(field)
    count = reset_member_extra(field_atom)
    new_count = count_members_with_extra(field_atom)

    Tokengate.Auditing.audit(
      socket.assigns.current_user,
      "settings.reset_member_extra",
      "team_member",
      nil,
      %{"field" => field, "affected" => count}
    )

    count_assign =
      case field_atom do
        :extra_monthly_budget_usd -> {:extras_budget_count, new_count}
        :extra_concurrency -> {:extras_concurrency_count, new_count}
        :extra_rpm -> {:extras_rpm_count, new_count}
      end

    label =
      case field_atom do
        :extra_monthly_budget_usd -> "Presupuesto mensual"
        :extra_concurrency -> "Concurrencia"
        :extra_rpm -> "RPM"
      end

    socket =
      socket
      |> assign(:extras_reset_type, nil)
      |> put_flash(:info, "#{label} reiniciado en #{count} miembros.")

    socket = socket |> assign(elem(count_assign, 0), elem(count_assign, 1))

    {:noreply, socket}
  end

  ## Cost backfill ----------------------------------------------------------

  @impl true
  def handle_event("show_backfill_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_backfill, true)}
  end

  @impl true
  def handle_event("cancel_backfill", _params, socket) do
    {:noreply, assign(socket, :confirm_backfill, false)}
  end

  @impl true
  def handle_event("run_backfill", _params, socket) do
    {:ok, {updated, _skipped}} = CostBackfill.run()

    Tokengate.Auditing.audit(
      socket.assigns.current_user,
      "settings.backfill_costs",
      "request_logs",
      nil,
      %{"updated" => updated}
    )

    {:noreply,
     socket
     |> assign(:confirm_backfill, false)
     |> assign(:backfill_count, 0)
     |> put_flash(:info, "Costo recalculado en #{updated} logs.")}
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

        <%!-- Global Daily Cap --%>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.icon name="hero-banknotes" class="w-5 h-5" /> Límite de gasto diario global
            </h2>
            <p class="text-sm text-base-content/60">
              Tope máximo de gasto total por día (UTC). Cuando se alcanza,
              toda nueva request se rechaza con 402 hasta el día siguiente.
              Tiene prioridad sobre los límites mensuales y por credential.
              Vacío = sin límite.
            </p>

            <.form for={@global_form} id="global-cap-form" phx-submit="save_global_cap">
              <.input
                field={@global_form[:daily_max_spend_usd]}
                type="number"
                step="0.01"
                min="0"
                label="USD por día"
                hint="Ej: 50.00 — se corta todo cuando el gasto total del día llega a este monto."
              />
              <div class="flex gap-2 mt-3">
                <button type="submit" class="btn btn-primary btn-sm" id="save-global-cap-btn">
                  Guardar
                </button>
              </div>
            </.form>

            <div class="mt-4">
              <div class="flex justify-between text-sm">
                <span class="text-base-content/60">Gastado hoy</span>
                <span class="font-mono font-semibold">
                  ${Decimal.round(@global_daily_spend, 2)}
                  <%= if @global_daily_cap do %>
                    / ${Decimal.round(@global_daily_cap, 2)}
                  <% end %>
                </span>
              </div>
              <%= if @global_daily_cap && @global_daily_pct do %>
                <progress
                  class="progress w-full mt-1"
                  class={
                    if @global_daily_pct >= 90,
                      do: "progress progress-error w-full mt-1",
                      else: "progress progress-warning w-full mt-1"
                  }
                  value={@global_daily_pct}
                  max="100"
                />
              <% end %>
            </div>
          </div>
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

            <h3 class="font-semibold text-base-content mb-2">Reiniciar extras de miembros</h3>
            <p class="text-sm text-base-content/60 mb-3">
              Reinicia un campo extra específico de todos los miembros a los valores por defecto de su equipo.
              El gasto acumulado NO se resetea.
            </p>

            <div class="space-y-2">
              <div class="flex items-center justify-between">
                <div>
                  <span class="text-sm font-medium text-base-content">Presupuesto mensual (USD)</span>
                  <span class="text-xs text-base-content/50 ml-2">
                    <span class="font-mono">{@extras_budget_count}</span> miembros
                  </span>
                </div>
                <button
                  type="button"
                  phx-click="show_extras_reset_confirm"
                  phx-value-field="extra_monthly_budget_usd"
                  class="btn btn-warning btn-outline btn-xs"
                  id="reset-extras-budget-btn"
                  disabled={@extras_budget_count == 0}
                >
                  Reiniciar
                </button>
              </div>

              <div class="flex items-center justify-between">
                <div>
                  <span class="text-sm font-medium text-base-content">Concurrencia</span>
                  <span class="text-xs text-base-content/50 ml-2">
                    <span class="font-mono">{@extras_concurrency_count}</span> miembros
                  </span>
                </div>
                <button
                  type="button"
                  phx-click="show_extras_reset_confirm"
                  phx-value-field="extra_concurrency"
                  class="btn btn-warning btn-outline btn-xs"
                  id="reset-extras-concurrency-btn"
                  disabled={@extras_concurrency_count == 0}
                >
                  Reiniciar
                </button>
              </div>

              <div class="flex items-center justify-between">
                <div>
                  <span class="text-sm font-medium text-base-content">RPM</span>
                  <span class="text-xs text-base-content/50 ml-2">
                    <span class="font-mono">{@extras_rpm_count}</span> miembros
                  </span>
                </div>
                <button
                  type="button"
                  phx-click="show_extras_reset_confirm"
                  phx-value-field="extra_rpm"
                  class="btn btn-warning btn-outline btn-xs"
                  id="reset-extras-rpm-btn"
                  disabled={@extras_rpm_count == 0}
                >
                  Reiniciar
                </button>
              </div>
            </div>

            <div class="divider my-2"></div>

            <div class="flex items-center justify-between">
              <div>
                <h3 class="font-semibold text-base-content">Recalcular costos históricos</h3>
                <p class="text-sm text-base-content/60">
                  Recalcula el costo de logs pasados que quedaron en $0 porque el
                  proveedor no reportó costo (ej. LiteLLM streaming). Usa los
                  precios manuales de entrada/salida configurados en cada provider.
                  Solo afecta logs con <code>billing_mode = pay_per_token</code>
                  que tengan ambos precios configurados.
                </p>
                <p class="text-sm text-base-content/60 mt-1">
                  Hay <span class="font-mono font-semibold">{@backfill_count}</span> logs elegibles.
                </p>
              </div>
              <button
                type="button"
                phx-click="show_backfill_confirm"
                class="btn btn-primary btn-outline btn-sm"
                id="backfill-costs-btn"
                disabled={@backfill_count == 0}
              >
                Recalcular
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

      <%!-- Confirmation modal: reset member extra field --%>
      <%= if @extras_reset_type do %>
        <% field_label =
          case @extras_reset_type do
            :extra_monthly_budget_usd -> "presupuesto mensual (USD)"
            :extra_concurrency -> "concurrencia"
            :extra_rpm -> "RPM"
          end

        field_name =
          case @extras_reset_type do
            :extra_monthly_budget_usd -> "extra_monthly_budget_usd"
            :extra_concurrency -> "extra_concurrency"
            :extra_rpm -> "extra_rpm"
          end %>
        <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_extras_reset" />
          <div class="relative card bg-base-100 border border-warning/50 shadow-xl w-full max-w-md">
            <div class="card-body">
              <h3 class="card-title text-warning flex items-center gap-2">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> ¿Reiniciar {field_label}?
              </h3>
              <p class="text-sm text-base-content/70 mt-2">
                Esto pondrá <code>{field_name}</code>
                en <strong>nil</strong>
                para todos los miembros que tengan un valor distinto de nil.
              </p>
              <p class="text-sm text-base-content/70 mt-1">
                Cada miembro quedará con el valor por defecto de su equipo.
                El gasto acumulado <strong>no se resetea</strong>.
              </p>
              <div class="flex gap-2 mt-4 justify-end">
                <button type="button" phx-click="cancel_extras_reset" class="btn btn-ghost btn-sm">
                  Cancelar
                </button>
                <button
                  type="button"
                  phx-click="reset_extra"
                  phx-value-field={field_name}
                  class="btn btn-warning btn-sm"
                  id="confirm-reset-extra-btn"
                >
                  Sí, reiniciar
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Confirmation modal: backfill costs --%>
      <div :if={@confirm_backfill} class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/50" phx-click="cancel_backfill" />
        <div class="relative card bg-base-100 border border-primary/50 shadow-xl w-full max-w-md">
          <div class="card-body">
            <h3 class="card-title flex items-center gap-2">
              <.icon name="hero-currency-dollar" class="w-5 h-5" /> ¿Recalcular costos históricos?
            </h3>
            <p class="text-sm text-base-content/70 mt-2">
              Se actualizarán <strong>{@backfill_count}</strong> logs que tienen
              <code>provider_cost_usd = $0</code>, usando los precios manuales
              de entrada y salida configurados en cada provider.
            </p>
            <p class="text-sm text-base-content/70 mt-1">
              Solo se actualizan logs donde el provider tenga ambos precios
              configurados y <code>billing_mode = pay_per_token</code>.
              Los logs con costo ya reportado no se tocan.
            </p>
            <p class="text-sm text-base-content/70 mt-1">
              Esta acción <strong>no se puede deshacer</strong>.
            </p>
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_backfill" class="btn btn-ghost btn-sm">
                Cancelar
              </button>
              <button
                type="button"
                phx-click="run_backfill"
                class="btn btn-primary btn-sm"
                id="confirm-backfill-btn"
              >
                Sí, recalcular
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Helpers ----------------------------------------------------------------

  defp assign_global_settings(socket) do
    settings = GlobalSettings.get!()
    daily_spend = Budgets.global_daily_spend()
    daily_cap = settings.daily_max_spend_usd

    daily_pct =
      if daily_cap && Decimal.compare(daily_cap, Decimal.new(0)) == :gt do
        Decimal.div(daily_spend, daily_cap)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(1)
        |> Decimal.to_float()
      else
        nil
      end

    socket
    |> assign(
      :global_form,
      to_form(GlobalSettings.changeset(settings, %{}), as: :global_settings)
    )
    |> assign(:global_daily_spend, daily_spend)
    |> assign(:global_daily_cap, daily_cap)
    |> assign(:global_daily_pct, daily_pct)
  end

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

  defp count_members_with_extra(field) do
    import Ecto.Query

    Repo.one(
      from(tm in "team_members",
        where: not is_nil(field(tm, ^field)),
        select: count(tm.id)
      )
    )
  end

  @extra_fields ~w(extra_monthly_budget_usd extra_concurrency extra_rpm)a

  defp reset_member_extra(field) when field in @extra_fields do
    import Ecto.Query

    {count, _} =
      Repo.update_all(
        from(tm in "team_members", where: not is_nil(field(tm, ^field))),
        set: [{field, nil}, {:updated_at, DateTime.truncate(DateTime.utc_now(), :second)}]
      )

    count
  end
end
