defmodule TokengateWeb.GroupsLive do
  @moduledoc """
  Admin-only CRUD for groups + per-group model model grants + observability webhooks.

  Only admins (global_role == "admin") can access this page. Non-admins
  are redirected to /dashboard with an error flash.

  Groups carry default budgets and limits applied to all members. Model
  models can be granted per-group via the group_models join table.
  Observability destinations (webhooks) are managed per-group.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Accounts
  alias Tokengate.Accounts.Group
  alias Tokengate.Budgets
  alias Tokengate.Observability
  alias Tokengate.Observability.Destination
  alias Tokengate.Providers
  alias Tokengate.Providers.{Model, GroupModel}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user.global_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, "No tienes permisos para acceder a esta sección.")
       |> redirect(to: "/dashboard")}
    else
      socket =
        socket
        |> assign(:page_title, "Grupos · Tokengate")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:form, nil)
        |> assign(:editing_group_id, nil)
        |> assign(:webhook_form, nil)
        |> assign(:editing_webhook_group_id, nil)
        |> assign(:editing_webhook_id, nil)
        |> assign(:editing_models_group_id, nil)
        |> assign(:group_search, "")
        |> load_groups()

      {:ok, socket}
    end
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

  ## Data loading ---------------------------------------------------------

  # Loads the full dataset ONCE per mount (and after data mutations that
  # change groups themselves). Search and modal toggles must NOT come through
  # here — they filter in-memory / touch no data (see the assign-only handlers).
  defp load_groups(socket) do
    groups =
      from(t in Group,
        preload: [:group_members],
        order_by: [asc: t.name]
      )
      |> Repo.all()

    granted_models =
      from(tma in GroupModel, select: {tma.group_id, tma.model_id})
      |> Repo.all()
      |> Enum.group_by(fn {group_id, _} -> group_id end, fn {_, model_id} -> model_id end)

    models_by_org =
      from(ma in Model, order_by: [asc: ma.name])
      |> Repo.all()
      |> Enum.group_by(fn _ma -> "all" end)

    # Single query for all groups' destinations (avoids one query per group)
    destinations_by_group =
      Observability.list_destinations_for_groups(Enum.map(groups, & &1.id))

    # Budget + spend rollup per group and per member
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    member_budgets = Budgets.list_member_budgets(timezone)

    group_budgets =
      member_budgets
      |> Enum.group_by(fn mb -> mb.member.group_id end)
      |> Map.new(fn {group_id, budgets} ->
        group = Enum.find(groups, &(&1.id == group_id))

        monthly_limit_usd =
          budgets
          |> Enum.map(& &1.monthly_limit_usd)
          |> Enum.reject(&is_nil/1)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

        monthly_spend_usd =
          Enum.reduce(budgets, Decimal.new(0), &Decimal.add(&1.monthly_spend_usd, &2))

        estimated_monthly_usd =
          if group && group.monthly_budget_per_user_usd do
            group.monthly_budget_per_user_usd
            |> Decimal.mult(Decimal.new(length(budgets)))
          else
            nil
          end

        estimated_monthly_extra_usd =
          Enum.reduce(budgets, Decimal.new(0), fn mb, acc ->
            if mb.member.extra_monthly_budget_usd,
              do: Decimal.add(acc, mb.member.extra_monthly_budget_usd),
              else: acc
          end)

        {group_id,
         %{
           monthly_limit_usd: monthly_limit_usd,
           monthly_spend_usd: monthly_spend_usd,
           estimated_monthly_usd: estimated_monthly_usd,
           estimated_monthly_extra_usd: estimated_monthly_extra_usd,
           member_count: length(budgets),
           member_budgets: budgets
         }}
      end)

    socket
    |> assign(:all_groups, groups)
    |> stream_groups()
    |> assign(:groups_empty?, groups == [])
    |> assign(:granted_models, granted_models)
    |> assign(:models_by_org, models_by_org)
    |> assign(:destinations_by_group, destinations_by_group)
    |> assign(:group_budgets, group_budgets)
  end

  # Re-streams the (already loaded) groups filtered by the current search.
  # Pure assign work: zero queries.
  defp stream_groups(socket) do
    search = socket.assigns[:group_search] || ""
    search_down = String.downcase(search)

    filtered =
      Enum.filter(socket.assigns.all_groups, fn t ->
        search == "" or String.contains?(String.downcase(t.name), search_down)
      end)

    socket
    |> stream(:groups, filtered, reset: true)
    |> assign(:groups_empty?, filtered == [])
  end

  ## Events — group CRUD ---------------------------------------------------

  @impl true
  def handle_event("search_groups", %{"group_search" => search}, socket) do
    # Groups are already in memory — filter + re-stream, no queries.
    {:noreply, socket |> assign(:group_search, search) |> stream_groups()}
  end

  @impl true
  def handle_event("new_group", _params, socket) do
    changeset = Accounts.change_group(%Group{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :group))
     |> assign(:editing_group_id, :new)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_group_id, nil)}
  end

  def handle_event("edit_models", %{"id" => group_id}, socket) do
    {:noreply, assign(socket, :editing_models_group_id, group_id)}
  end

  def handle_event("close_models", _params, socket) do
    {:noreply, assign(socket, :editing_models_group_id, nil)}
  end

  def handle_event("edit_group", %{"id" => group_id}, socket) do
    group = Accounts.get_group!(group_id)
    changeset = Accounts.change_group(group)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :group))
     |> assign(:editing_group_id, group.id)}
  end

  def handle_event("save_group", %{"group" => group_params}, socket) do
    save_group(socket, socket.assigns.editing_group_id, group_params)
  end

  def handle_event("delete_group", %{"id" => group_id}, socket) do
    group = Accounts.get_group!(group_id)

    case Accounts.delete_group(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Grupo eliminado.")
         |> load_groups()}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field} #{message}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, "No se pudo eliminar: #{msg}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el grupo.")}
    end
  end

  ## Events — model grants ------------------------------------------------

  def handle_event("toggle_model", %{"group-id" => group_id, "model-id" => model_id}, socket) do
    group_alias_ids = Map.get(socket.assigns.granted_models, group_id, [])

    result =
      if model_id in group_alias_ids do
        Providers.revoke_model_from_group(group_id, model_id)
      else
        Providers.grant_model_to_group(group_id, model_id)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Modelos actualizados.")
         |> refresh_granted_models()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar el modelo.")}
    end
  end

  ## Events — webhook CRUD -----------------------------------------------

  def handle_event("new_webhook", params, socket) do
    group_id = params["group-id"] || params["group_id"]
    changeset = Observability.change_destination(%Destination{})

    # Modal-only change: no data touched, skip the full reload.
    {:noreply,
     socket
     |> assign(:webhook_form, to_form(changeset, as: :destination))
     |> assign(:editing_webhook_group_id, group_id)
     |> assign(:editing_webhook_id, :new)}
  end

  def handle_event("edit_webhook", params, socket) do
    group_id = params["group-id"] || params["group_id"]
    webhook_id = params["webhook-id"] || params["webhook_id"]
    destination = Observability.get_destination!(webhook_id)
    changeset = Observability.change_destination(destination)

    {:noreply,
     socket
     |> assign(:webhook_form, to_form(changeset, as: :destination))
     |> assign(:editing_webhook_group_id, group_id)
     |> assign(:editing_webhook_id, webhook_id)}
  end

  def handle_event("cancel_webhook", _params, socket) do
    # Modal-only change: no data touched, skip the full reload.
    {:noreply,
     socket
     |> assign(:webhook_form, nil)
     |> assign(:editing_webhook_group_id, nil)
     |> assign(:editing_webhook_id, nil)}
  end

  def handle_event("save_webhook", %{"destination" => destination_params}, socket) do
    group_id = socket.assigns.editing_webhook_group_id
    editing_id = socket.assigns.editing_webhook_id

    # Parse headers from JSON string if present
    destination_params =
      Map.update(destination_params, "headers", %{}, fn
        headers when is_map(headers) ->
          headers

        headers when is_binary(headers) and headers != "" ->
          case Jason.decode(headers) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{"_raw" => headers}
          end

        _ ->
          %{}
      end)

    destination_params = Map.put(destination_params, "group_id", group_id)

    result =
      if editing_id == :new do
        Observability.create_destination(destination_params)
      else
        destination = Observability.get_destination!(editing_id)
        Observability.update_destination(destination, destination_params)
      end

    case result do
      {:ok, _destination} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook guardado.")
         |> assign(:webhook_form, nil)
         |> assign(:editing_webhook_group_id, nil)
         |> assign(:editing_webhook_id, nil)
         |> refresh_destinations()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :webhook_form, to_form(changeset, as: :destination))}
    end
  end

  def handle_event("delete_webhook", params, socket) do
    webhook_id = params["webhook-id"] || params["webhook_id"]
    destination = Observability.get_destination!(webhook_id)

    case Observability.delete_destination(destination) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook eliminado.")
         |> refresh_destinations()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el webhook.")}
    end
  end

  # Surgical refresh: only the table that actually changed, instead of the
  # full load_groups() (groups + members + models + destinations + 2 spend
  # aggregates).
  defp refresh_granted_models(socket) do
    granted_models =
      from(tma in GroupModel, select: {tma.group_id, tma.model_id})
      |> Repo.all()
      |> Enum.group_by(fn {group_id, _} -> group_id end, fn {_, model_id} -> model_id end)

    assign(socket, :granted_models, granted_models)
  end

  defp refresh_destinations(socket) do
    group_ids = Enum.map(socket.assigns.all_groups, & &1.id)
    assign(socket, :destinations_by_group, Observability.list_destinations_for_groups(group_ids))
  end

  ## Private helpers — save ----------------------------------------------

  defp save_group(socket, :new, group_params) do
    case Accounts.create_group(group_params) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Grupo creado.")
         |> assign(:form, nil)
         |> assign(:editing_group_id, nil)
         |> load_groups()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :group))}
    end
  end

  defp save_group(socket, group_id, group_params) when is_binary(group_id) do
    group = Accounts.get_group!(group_id)

    case Accounts.update_group(group, group_params) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Grupo actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_group_id, nil)
         |> load_groups()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :group))}
    end
  end

  ## Template helpers -----------------------------------------------------

  def format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  def format_decimal(nil), do: "—"
  def format_decimal(value), do: to_string(value)

  # The `headers` destination field is a :map column, but the form edits it as
  # a JSON string in a textarea. Convert the map to JSON for display; empty
  # maps render as an empty textarea. Invalid JSON submitted previously is
  # stored as %{"_raw" => original} — show the original string back.
  def headers_to_string(%{} = headers) when map_size(headers) == 0, do: ""

  def headers_to_string(%{} = headers) do
    case Map.get(headers, "_raw") do
      nil -> Jason.encode!(headers, pretty: true)
      raw -> raw
    end
  end

  def headers_to_string(_), do: ""

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Grupos
          <:subtitle>Gestiona grupos, presupuestos, models de models y webhooks</:subtitle>
          <:actions>
            <div class="flex items-center gap-2">
              <input
                type="text"
                name="group_search"
                value={@group_search}
                placeholder="Buscar grupo…"
                phx-change="search_groups"
                phx-debounce="200"
                class="input input-sm w-48"
              />
              <.button phx-click="new_group" id="new-group-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> Nuevo grupo
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- Group form (create / edit) — modal --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_group_id == :new, do: "Nuevo grupo", else: "Editar grupo"}
              </h2>
              <.form for={@form} id="group-form" phx-submit="save_group">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Nombre"
                  hint="Nombre identificativo del grupo."
                />
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <.input
                    field={@form[:monthly_budget_per_user_usd]}
                    type="number"
                    label="Budget mensual por usuario (USD)"
                    step="any"
                    hint="Presupuesto mensual individual para cada miembro. Vacío = sin límite."
                  />
                  <.input
                    field={@form[:default_concurrency_limit]}
                    type="number"
                    label="Concurrencia"
                    hint="Concurrencia por miembro. Cada miembro puede tener un extra que se suma a este valor."
                  />
                  <.input
                    field={@form[:default_rpm_limit]}
                    type="number"
                    label="RPM"
                    hint="Requests por minuto por miembro."
                  />
                </div>
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-group-btn">Guardar</button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Aliases modal — manage model grants per group per group --%>
        <div
          :if={@editing_models_group_id}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id={"models-modal-#{@editing_models_group_id}"}
        >
          <div class="absolute inset-0 bg-black/50" phx-click="close_models" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">Modelos del grupo</h2>
              <p class="text-sm text-base-content/60 -mt-2 mb-4">
                Toca un modelo para otorgarlo o revocarlo al grupo.
              </p>
              <div class="flex flex-wrap gap-2" id={"model-picker-#{@editing_models_group_id}"}>
                <button
                  :for={model <- Map.get(@models_by_org, "all", [])}
                  type="button"
                  phx-click="toggle_model"
                  phx-value-group-id={@editing_models_group_id}
                  phx-value-model-id={model.id}
                  class={[
                    "badge badge-sm cursor-pointer transition-all",
                    if(
                      model.id in Map.get(@granted_models, @editing_models_group_id, []),
                      do: "badge-primary",
                      else: "badge-outline"
                    )
                  ]}
                  id={"model-#{@editing_models_group_id}-#{model.id}"}
                >
                  {model.name}
                </button>
                <p
                  :if={Map.get(@models_by_org, "all", []) == []}
                  class="text-xs text-base-content/40"
                >
                  No hay models disponibles.
                </p>
              </div>
              <div class="flex justify-end mt-4">
                <button
                  type="button"
                  phx-click="close_models"
                  class="btn btn-primary btn-sm"
                  id="close-models-btn"
                >
                  Listo
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Webhook form (create / edit) — modal --%>
        <div
          :if={@webhook_form}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id={"webhook-form-#{@editing_webhook_group_id}"}
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_webhook" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_webhook_id == :new, do: "Nuevo webhook", else: "Editar webhook"}
              </h2>
              <.form
                for={@webhook_form}
                id={"destination-form-#{@editing_webhook_group_id}"}
                phx-submit="save_webhook"
              >
                <.input
                  field={@webhook_form[:name]}
                  type="text"
                  label="Nombre"
                  hint="Nombre identificativo del webhook. Ej.: «Datadog - Producción»."
                />
                <.input
                  field={@webhook_form[:url]}
                  type="text"
                  label="URL"
                  hint="Endpoint HTTPS donde se enviarán los datos de telemetría (formato OTLP)."
                />
                <.input
                  field={@webhook_form[:headers]}
                  value={headers_to_string(@webhook_form[:headers].value)}
                  type="textarea"
                  label="Cabeceras (JSON)"
                  placeholder='{"Authorization": "Bearer xxx"}'
                  hint="Cabeceras HTTP adicionales en formato JSON. Dejalo vacio si no necesitas cabeceras extra."
                />
                <div class="flex gap-2 mt-4 justify-end">
                  <button
                    type="button"
                    phx-click="cancel_webhook"
                    class="btn btn-ghost btn-sm"
                    id={"cancel-webhook-#{@editing_webhook_group_id}"}
                  >
                    Cancelar
                  </button>
                  <button
                    type="submit"
                    class="btn btn-primary btn-sm"
                    id={"save-webhook-#{@editing_webhook_group_id}"}
                  >
                    Guardar
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <div id="groups" phx-update="stream">
          <div :if={@groups_empty?} class="text-center py-12 text-base-content/40" id="groups-empty">
            <.icon name="hero-user-group" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>No hay grupos todavía.</p>
          </div>
          <div
            :for={{id, group} <- @streams.groups}
            id={id}
            class="card bg-base-100 border border-base-300 shadow-sm mb-4 transition-shadow hover:shadow-md"
          >
            <div class="card-body">
              <div class="flex items-start justify-between">
                <div>
                  <h3 class="font-semibold text-base-content">{group.name}</h3>
                  <p class="text-xs text-base-content/50 mt-0.5">
                    {length(group.group_members)} miembros
                  </p>
                </div>
                <div class="flex gap-2">
                  <.link
                    navigate={~p"/admin/groups/#{group}/members"}
                    class="btn btn-sm btn-ghost"
                    id={"members-link-#{group.id}"}
                  >
                    Miembros
                  </.link>
                  <button
                    phx-click="edit_group"
                    phx-value-id={group.id}
                    class="btn btn-sm btn-ghost"
                    id={"edit-#{group.id}"}
                  >
                    Editar
                  </button>
                  <button
                    phx-click="edit_models"
                    phx-value-id={group.id}
                    class="btn btn-sm btn-ghost"
                    id={"edit-models-#{group.id}"}
                    title="Gestionar models de models"
                  >
                    Aliases
                  </button>
                  <button
                    phx-click="new_webhook"
                    phx-value-group-id={group.id}
                    class="btn btn-sm btn-ghost gap-1"
                    id={"new-webhook-#{group.id}"}
                    title="Agregar webhook de observabilidad"
                  >
                    <.icon name="hero-bell-alert" class="w-4 h-4" /> Webhook
                  </button>
                  <button
                    phx-click="delete_group"
                    phx-value-id={group.id}
                    class="btn btn-sm btn-ghost text-error"
                    id={"delete-#{group.id}"}
                    data-confirm="¿Eliminar grupo? Esta acción no se puede deshacer."
                  >
                    Eliminar
                  </button>
                </div>
              </div>

              <% tb =
                Map.get(@group_budgets, group.id, %{
                  monthly_limit_usd: Decimal.new(0),
                  monthly_spend_usd: Decimal.new(0),
                  estimated_monthly_usd: nil,
                  estimated_monthly_extra_usd: Decimal.new(0),
                  member_count: 0,
                  member_budgets: []
                }) %>

              <%!-- Stats cards: configuración + gasto — 5 tarjetas --%>
              <div class="mt-3 grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
                <%!-- Budget mensual/usuario --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Budget/mes
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-primary/10">
                        <.icon name="hero-banknotes" class="w-4 h-4 text-primary" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      ${format_decimal(group.monthly_budget_per_user_usd)}
                    </p>
                    <p class="text-xs text-base-content/40">por usuario</p>
                  </div>
                </div>

                <%!-- Concurrencia/usuario --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Concurrencia
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-accent/10">
                        <.icon name="hero-arrows-right-left" class="w-4 h-4 text-accent" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {group.default_concurrency_limit}
                    </p>
                    <p class="text-xs text-base-content/40">por usuario</p>
                  </div>
                </div>

                <%!-- RPM/usuario --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        RPM
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-accent/10">
                        <.icon name="hero-bolt" class="w-4 h-4 text-accent" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {group.default_rpm_limit}
                    </p>
                    <p class="text-xs text-base-content/40">por usuario</p>
                  </div>
                </div>

                <%!-- Gasto mensual --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Gasto/mes
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-success/10">
                        <.icon name="hero-currency-dollar" class="w-4 h-4 text-success" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      ${format_decimal(tb.monthly_spend_usd)}
                    </p>
                    <p class="text-xs text-base-content/40">real</p>
                  </div>
                </div>

                <%!-- Estimado mensual --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Estimado/mes
                      </span>
                      <span class={[
                        "flex items-center justify-center w-8 h-8 rounded-lg",
                        if(
                          tb.estimated_monthly_extra_usd &&
                            Decimal.compare(tb.estimated_monthly_extra_usd, 0) == :gt,
                          do: "bg-success/10",
                          else: "bg-primary/10"
                        )
                      ]}>
                        <.icon
                          name="hero-calculator"
                          class={[
                            "w-4 h-4",
                            if(
                              tb.estimated_monthly_extra_usd &&
                                Decimal.compare(tb.estimated_monthly_extra_usd, 0) == :gt,
                              do: "text-success",
                              else: "text-primary"
                            )
                          ]}
                        />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      ${format_decimal(
                        Decimal.add(
                          tb.estimated_monthly_usd || Decimal.new(0),
                          tb.estimated_monthly_extra_usd
                        )
                      )}
                    </p>
                    <%= if Decimal.compare(tb.estimated_monthly_extra_usd, 0) == :gt do %>
                      <p class="text-xs text-success">
                        ${format_decimal(tb.estimated_monthly_usd)} base + ${format_decimal(
                          tb.estimated_monthly_extra_usd
                        )} extra
                      </p>
                    <% else %>
                      <p class="text-xs text-base-content/40">proyección</p>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Webhooks section --%>
              <div class="mt-4 pt-4 border-t border-base-300">
                <h4 class="text-sm font-semibold flex items-center gap-1.5 mb-3">
                  <.icon name="hero-bell-alert" class="w-4 h-4 opacity-70" />
                  Webhooks de observabilidad
                </h4>

                <!-- Destination list -->
                <div id={"webhooks-list-#{group.id}"}>
                  <div
                    :for={destination <- Map.get(@destinations_by_group, group.id, [])}
                    class="flex items-center justify-between gap-3 py-2 px-3 rounded-lg bg-base-200/50 hover:bg-base-200 transition-colors mb-2"
                    id={"webhook-#{destination.id}"}
                  >
                    <div class="flex items-center gap-3 min-w-0">
                      <span class="badge badge-sm badge-primary/20 border-primary/30 text-primary">
                        {destination.type}
                      </span>
                      <div class="min-w-0">
                        <p class="text-sm font-medium truncate">{destination.name}</p>
                        <p class="text-xs text-base-content/40 truncate">{destination.url}</p>
                      </div>
                    </div>
                    <div class="flex gap-1 shrink-0">
                      <button
                        phx-click="edit_webhook"
                        phx-value-group-id={group.id}
                        phx-value-webhook-id={destination.id}
                        class="btn btn-xs btn-ghost"
                        id={"edit-webhook-#{destination.id}"}
                        title="Editar webhook"
                      >
                        <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                      </button>
                      <button
                        phx-click="delete_webhook"
                        phx-value-webhook-id={destination.id}
                        class="btn btn-xs btn-ghost text-error"
                        id={"delete-webhook-#{destination.id}"}
                        data-confirm="¿Eliminar webhook? Esta acción no se puede deshacer."
                        title="Eliminar webhook"
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" />
                      </button>
                    </div>
                  </div>

                  <div
                    :if={Map.get(@destinations_by_group, group.id, []) == []}
                    class="text-center py-6 text-base-content/40"
                    id={"webhooks-empty-#{group.id}"}
                  >
                    <.icon name="hero-bell-slash" class="w-8 h-8 mx-auto mb-1.5 opacity-40" />
                    <p class="text-xs">No hay webhooks configurados para este grupo.</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
