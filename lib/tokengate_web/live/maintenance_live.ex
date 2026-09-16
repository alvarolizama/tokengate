defmodule TokengateWeb.MaintenanceLive do
  @moduledoc """
  Admin maintenance page — read-only config overview plus Danger Zone actions.

  Currently supports:
    * Reset all request logs (truncate `request_logs` table)
    * Reset sticky sessions
    * Reset per-field member extras (budget, concurrency, rpm)
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Accounts
  alias Tokengate.Budgets.Exemption
  alias Tokengate.Budgets.Exemptions
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.GlobalSettings
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
      |> assign(:extras_reset_type, nil)
      |> assign(:log_count, count_logs())
      |> assign(:sticky_count, sticky_count())
      |> assign(:extras_concurrency_count, count_members_with_extra(:extra_concurrency))
      |> assign(:extras_rpm_count, count_members_with_extra(:extra_rpm))
      |> assign(:global_subject_type, "user")
      |> assign(:groups, Accounts.list_groups())
      |> assign(:services, Accounts.list_services())
      |> assign(:users, Accounts.list_users())
      |> assign_global_settings()
      |> assign_exemptions()
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

  @impl true
  def handle_event("show_extras_reset_confirm", %{"field" => field}, socket)
      when field in ["extra_concurrency", "extra_rpm"] do
    {:noreply, assign(socket, :extras_reset_type, String.to_existing_atom(field))}
  end

  @impl true
  def handle_event("cancel_extras_reset", _params, socket) do
    {:noreply, assign(socket, :extras_reset_type, nil)}
  end

  @impl true
  def handle_event("reset_extra", %{"field" => field}, socket)
      when field in ["extra_concurrency", "extra_rpm"] do
    field_atom = String.to_existing_atom(field)
    count = reset_member_extra(field_atom)
    new_count = count_members_with_extra(field_atom)

    Tokengate.Auditing.audit(
      socket.assigns.current_user,
      "settings.reset_member_extra",
      "group_member",
      nil,
      %{"field" => field, "affected" => count}
    )

    count_assign =
      case field_atom do
        :extra_concurrency -> {:extras_concurrency_count, new_count}
        :extra_rpm -> {:extras_rpm_count, new_count}
      end

    label =
      case field_atom do
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

  ## Global daily spending cap (kill-switch) --------------------------------

  @impl true
  def handle_event("save_global_cap", %{"global_settings" => params}, socket) do
    case GlobalSettings.update(params) do
      {:ok, _settings} ->
        Tokengate.Auditing.audit(
          socket.assigns.current_user,
          "budget.update_global_daily_cap",
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
  def handle_event("change_global_subject", %{"global_subject" => %{"subject_type" => t}}, socket) do
    {:noreply, assign(socket, :global_subject_type, t)}
  end

  def handle_event("add_global_exemption", %{"global_subject" => params}, socket) do
    subject_type = params["subject_type"]
    subject_id = params["subject_id"]

    cond do
      subject_type in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Selecciona un tipo de sujeto.")}

      subject_id in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Selecciona a quién excluir.")}

      true ->
        attrs =
          %{"scope" => "global_daily", "subject_type" => subject_type}
          |> Map.put(to_string(Exemption.subject_field(subject_type)), subject_id)

        case Exemptions.add(attrs) do
          {:ok, _exemption} ->
            {:noreply, socket |> assign_exemptions() |> put_flash(:info, "Exención agregada.")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, exemption_error(changeset))}
        end
    end
  end

  def handle_event("remove_global_exemption", %{"id" => id}, socket) do
    Exemptions.remove(id)
    {:noreply, socket |> assign_exemptions() |> put_flash(:info, "Exención eliminada.")}
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

        <%!-- Global daily spending cap (kill-switch) --%>
        <div class="card bg-base-100 border border-base-300" id="global-cap-card">
          <div class="card-body">
            <h2 class="card-title flex items-center gap-2">
              <.icon name="hero-globe-americas" class="w-5 h-5" /> Límite de gasto diario global
            </h2>
            <p class="text-sm text-base-content/60">
              Tope máximo de gasto total por día (UTC), sumando todos los sujetos.
              Cuando se alcanza, toda nueva request se rechaza con 402 hasta el día
              siguiente. Vacío = sin límite.
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
                <span class="text-base-content/60">Gastado hoy (total)</span>
                <span class="font-mono font-semibold">
                  ${Decimal.round(@global_daily_spend, 2)}
                  <%= if @global_daily_cap do %>
                    / ${Decimal.round(@global_daily_cap, 2)}
                  <% end %>
                </span>
              </div>
              <%= if @global_daily_cap && @global_daily_pct do %>
                <progress
                  class={
                    if @global_daily_pct >= 90,
                      do: "progress progress-error w-full mt-1",
                      else: "progress progress-warning w-full mt-1"
                  }
                  value={@global_daily_pct}
                  max="100"
                />
              <% end %>
              <p class="text-xs text-base-content/40 mt-1">
                Gasto real de <code>request_logs</code>, día UTC
                (misma fuente que Estadísticas).
              </p>
              <%= if @global_daily_enforcement && drift?(@global_daily_enforcement, @global_daily_spend) do %>
                <p class="text-xs text-warning mt-1" id="global-enforcement-drift">
                  Contador de enforcement:
                  <span class="font-mono">
                    ${Decimal.round(@global_daily_enforcement, 2)}
                  </span>
                  — incluye los holds de las requests en vuelo.
                  <%= if Decimal.compare(@global_daily_enforcement, @global_daily_spend) == :gt do %>
                    Si no baja en unos minutos, es drift: el <code>GlobalSyncWorker</code>
                    lo reconcilia contra la DB.
                  <% else %>
                    Se sincroniza contra la DB al vuelo.
                  <% end %>
                </p>
              <% end %>
            </div>

            <div class="divider my-2"></div>
            <h3 class="font-semibold text-base-content flex items-center gap-2">
              <.icon name="hero-shield-exclamation" class="w-4 h-4 text-warning" />
              Exclusiones al límite global
            </h3>
            <p class="text-sm text-base-content/60">
              El gasto de estos sujetos no cuenta para el límite global (sigue
              contando para su propio crédito).
            </p>

            <.form
              for={%{}}
              phx-submit="add_global_exemption"
              phx-change="change_global_subject"
              id="global-exemption-form"
              class="flex flex-wrap gap-2 items-end"
            >
              <div>
                <label class="text-xs text-base-content/60 block mb-1">Tipo</label>
                <select name="global_subject[subject_type]" class="select select-bordered select-sm">
                  <option value="user" selected={@global_subject_type == "user"}>Usuario</option>
                  <option value="group" selected={@global_subject_type == "group"}>Grupo</option>
                  <option value="service" selected={@global_subject_type == "service"}>
                    Servicio
                  </option>
                </select>
              </div>
              <div class="flex-1 min-w-48">
                <label class="text-xs text-base-content/60 block mb-1">Sujeto</label>
                <select
                  name="global_subject[subject_id]"
                  class="select select-bordered select-sm w-full"
                >
                  <option value="">
                    {if @global_subject_type == "user",
                      do: "Usuario…",
                      else: if(@global_subject_type == "group", do: "Grupo…", else: "Servicio…")}
                  </option>
                  <%= for {label, id} <- subject_options(@global_subject_type, assigns) do %>
                    <option value={id}>{label}</option>
                  <% end %>
                </select>
              </div>
              <button type="submit" class="btn btn-ghost btn-sm">Excluir</button>
            </.form>

            <%= if @global_exemptions == [] do %>
              <p class="text-sm text-base-content/40">
                Sin exclusiones — todos sujetos al límite global.
              </p>
            <% else %>
              <ul class="space-y-1">
                <li
                  :for={e <- @global_exemptions}
                  id={"global-exemption-" <> e.id}
                  class="flex items-center justify-between text-sm bg-base-200/50 rounded-lg px-3 py-1.5"
                >
                  <span>{Exemptions.subject_label(e)}</span>
                  <button
                    type="button"
                    phx-click="remove_global_exemption"
                    phx-value-id={e.id}
                    class="btn btn-ghost btn-xs text-error"
                    aria-label="Quitar exención"
                  >
                    <.icon name="hero-x-mark" class="w-3 h-3" />
                  </button>
                </li>
              </ul>
            <% end %>
          </div>
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

            <h3 class="font-semibold text-base-content mb-2">Reiniciar extras de miembros</h3>
            <p class="text-sm text-base-content/60 mb-3">
              Reinicia un campo extra específico de todos los miembros a los valores por defecto de su grupo.
              El gasto acumulado NO se resetea.
            </p>

            <div class="space-y-2">
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

            <%!-- External data, not user data: the refresh upserts the mirror
                 from models.dev and re-materializes provider identity. Nothing
                 is deleted, so it belongs in the caution zone. --%>
            <div class="flex items-start justify-between gap-4" id="catalog-refresh-card">
              <div>
                <h3 class="font-semibold text-base-content">Catálogo de proveedores (models.dev)</h3>
                <p class="text-sm text-base-content/60">
                  Vuelve a bajar el catálogo de proveedores y actualiza nombre, base URL, docs y logo
                  de los builtins. No toca credenciales, modelos, routing ni proveedores custom, y no
                  borra nada: lo que ya no está upstream se marca como obsoleto.
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
                  </li>
                </ul>

                <p class="text-xs text-base-content/40 mt-1">
                  Proveedores en el catálogo: <span class="font-mono">{@catalog_active_count}</span>
                  activos, <span class="font-mono">{@catalog_stale_count}</span>
                  obsoletos.
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
                  No afecta usuarios, grupos, models, proveedores ni API keys.
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
              Usuarios, grupos, models, proveedores y API keys no se ven afectados.
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
            :extra_concurrency -> "concurrencia"
            :extra_rpm -> "RPM"
          end

        field_name =
          case @extras_reset_type do
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
                Cada miembro quedará con el valor por defecto de su grupo.
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

  defp count_members_with_extra(field) do
    import Ecto.Query

    Repo.one(
      from(tm in "group_members",
        where: not is_nil(field(tm, ^field)),
        select: count(tm.id)
      )
    )
  end

  @extra_fields ~w(extra_concurrency extra_rpm)a

  defp reset_member_extra(field) when field in @extra_fields do
    import Ecto.Query

    {count, _} =
      Repo.update_all(
        from(tm in "group_members", where: not is_nil(field(tm, ^field))),
        set: [{field, nil}, {:updated_at, DateTime.truncate(DateTime.utc_now(), :second)}]
      )

    count
  end

  ## Global cap helpers ------------------------------------------------------

  defp assign_global_settings(socket) do
    settings = GlobalSettings.get!()
    # Two different numbers, on purpose:
    #
    #   * `:global_daily_spend` — REAL spend from `request_logs` over the UTC
    #     day, the same source `/stats` displays. This is what the kill-switch
    #     compares against, so it is the number an operator must see here.
    #   * `:global_daily_enforcement` — the live ETS enforcement counter
    #     (`Budgets.Manager`). It carries the `$max_request_cost_usd` holds of
    #     in-flight requests, so it "breathes" with traffic and can hold a
    #     phantom peak if a request dies between hold and settle. Kept only as
    #     a drift reference, rendered when it disagrees with the real spend.
    real_spend =
      %{from: Budgets.utc_day_start()}
      |> Logs.cost_summary()
      |> Map.get(:total_cost_usd, Decimal.new(0))

    daily_cap = settings.daily_max_spend_usd

    daily_pct =
      if daily_cap && Decimal.compare(daily_cap, Decimal.new(0)) == :gt do
        real_spend
        |> Decimal.div(daily_cap)
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
    |> assign(:global_daily_spend, real_spend)
    |> assign(:global_daily_cap, daily_cap)
    |> assign(:global_daily_pct, daily_pct)
    |> assign(:global_daily_enforcement, enforcement_counter_spend())
  end

  # True when the enforcement counter and the real DB spend disagree by more
  # than half a cent — below that the difference is rounding noise between an
  # exact Decimal sum and the micro-USD ETS counter, not drift worth showing.
  defp drift?(enforcement, real_spend) do
    enforcement
    |> Decimal.sub(real_spend)
    |> Decimal.abs()
    |> Decimal.compare(Decimal.new("0.005")) == :gt
  end

  # The ETS enforcement counter as a Decimal, or `nil` when it cannot be read
  # (table not up yet on a cold boot). Never raises: the card is informational.
  defp enforcement_counter_spend do
    try do
      Budgets.global_daily_spend()
    rescue
      ArgumentError -> nil
    end
  end

  defp assign_exemptions(socket) do
    assign(socket, :global_exemptions, Exemptions.list_for_scope("global_daily"))
  end

  defp exemption_error(changeset) do
    case changeset.errors do
      [] ->
        "No se pudo agregar la exención."

      errors ->
        "No se pudo agregar la exención: " <>
          (errors |> Enum.map(fn {_, {m, _}} -> m end) |> Enum.join(", "))
    end
  end

  def subject_options("user", assigns),
    do: Enum.map(assigns.users, &{"#{&1.name} — #{&1.email}", &1.id})

  def subject_options("group", assigns), do: Enum.map(assigns.groups, &{&1.name, &1.id})
  def subject_options("service", assigns), do: Enum.map(assigns.services, &{&1.name, &1.id})
  def subject_options(_, _assigns), do: []
end
