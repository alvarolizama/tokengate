defmodule TokengateWeb.ObservabilityLive do
  @moduledoc """
  Admin-only CRUD for observability destinations (OTLP webhooks).

  Centralizes webhook management that used to live inline in each group
  card. Destinations are listed in a single compact table with search and
  group filter; groups link here instead of embedding webhook sections.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Observability
  alias Tokengate.Observability.Destination

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user && user.global_role == "admin" do
      socket =
        socket
        |> assign(:page_title, "Observabilidad · Tokengate")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:form, nil)
        |> assign(:editing_destination_id, nil)
        |> assign(:editing_group_id, nil)
        |> assign(:search, "")
        |> assign(:group_filter, "")
        |> load_data()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "No tienes permisos para acceder a esta sección.")
       |> redirect(to: "/dashboard")}
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

  defp load_data(socket) do
    destinations = Observability.list_all_destinations()
    groups = Accounts.list_groups()
    group_names = Map.new(groups, fn g -> {g.id, g.name} end)

    socket
    |> assign(:all_destinations, destinations)
    |> assign(:groups, groups)
    |> assign(:group_names, group_names)
    |> stream_destinations()
  end

  # Pure in-memory filter + re-stream: zero queries on search/filter events.
  defp stream_destinations(socket) do
    search = String.downcase(socket.assigns[:search] || "")
    group_filter = socket.assigns[:group_filter] || ""

    filtered =
      Enum.filter(socket.assigns.all_destinations, fn d ->
        name = String.downcase(d.name || "")
        url = String.downcase(d.url || "")
        group_name = String.downcase(Map.get(socket.assigns.group_names, d.group_id, ""))

        (search == "" or String.contains?(name, search) or String.contains?(url, search) or
           String.contains?(group_name, search)) and
          (group_filter == "" or d.group_id == group_filter)
      end)

    socket
    |> stream(:destinations, filtered, reset: true)
    |> assign(:destinations_empty?, filtered == [])
  end

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> stream_destinations()}
  end

  def handle_event("filter_group", %{"group_filter" => group_id}, socket) do
    {:noreply, socket |> assign(:group_filter, group_id) |> stream_destinations()}
  end

  def handle_event("new_destination", _params, socket) do
    changeset = Observability.change_destination(%Destination{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :destination))
     |> assign(:editing_destination_id, :new)
     |> assign(:editing_group_id, nil)}
  end

  def handle_event("edit_destination", %{"id" => id}, socket) do
    destination = Observability.get_destination!(id)
    changeset = Observability.change_destination(destination)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :destination))
     |> assign(:editing_destination_id, destination.id)
     |> assign(:editing_group_id, destination.group_id)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_destination_id, nil)
     |> assign(:editing_group_id, nil)}
  end

  def handle_event("save_destination", %{"destination" => destination_params}, socket) do
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

    result =
      if socket.assigns.editing_destination_id == :new do
        Observability.create_destination(destination_params)
      else
        destination = Observability.get_destination!(socket.assigns.editing_destination_id)
        Observability.update_destination(destination, destination_params)
      end

    case result do
      {:ok, _destination} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook guardado.")
         |> assign(:form, nil)
         |> assign(:editing_destination_id, nil)
         |> assign(:editing_group_id, nil)
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :destination))}
    end
  end

  def handle_event("delete_destination", %{"id" => id}, socket) do
    destination = Observability.get_destination!(id)

    case Observability.delete_destination(destination) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook eliminado.")
         |> load_data()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el webhook.")}
    end
  end

  ## Template helpers -----------------------------------------------------

  # The `headers` destination field is a :map column, but the form edits it as
  # a JSON string in a textarea. Convert the map to JSON for display; empty
  # maps render as an empty textarea. Invalid JSON submitted previously is
  # stored as %{"_raw" => original} — show the original string back.
  defp headers_to_string(%{} = headers) when map_size(headers) == 0, do: ""

  defp headers_to_string(%{} = headers) do
    case Map.get(headers, "_raw") do
      nil -> Jason.encode!(headers, pretty: true)
      raw -> raw
    end
  end

  defp headers_to_string(_), do: ""

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="space-y-6">
        <.header>
          Observabilidad
          <:subtitle>
            Webhooks de telemetría (OTLP) para todos los grupos, en un solo lugar
          </:subtitle>
          <:actions>
            <div class="flex items-center gap-2">
              <%!-- Igual que en grupos: el phx-change necesita un <form> alrededor.
                   El select lleva su PROPIO phx-change, que tiene precedencia
                   sobre el del form. --%>
              <form
                id="observability-search-form"
                phx-change="search"
                phx-submit="search"
                phx-debounce="200"
              >
                <input
                  type="text"
                  name="search"
                  value={@search}
                  placeholder="Buscar nombre o URL…"
                  class="input input-sm w-48"
                />
              </form>
              <form id="observability-group-filter-form" phx-change="filter_group">
                <select
                  name="group_filter"
                  class="select select-sm w-44"
                  id="group-filter"
                >
                  <option value="">Todos los grupos</option>
                  <option
                    :for={group <- @groups}
                    value={group.id}
                    selected={@group_filter == group.id}
                  >
                    {group.name}
                  </option>
                </select>
              </form>
              <.button phx-click="new_destination" id="new-destination-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> Nuevo webhook
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- Destination form (create / edit) — modal --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_destination_id == :new, do: "Nuevo webhook", else: "Editar webhook"}
              </h2>
              <.form for={@form} id="destination-form" phx-submit="save_destination">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Nombre"
                  hint="Nombre identificativo del webhook. Ej.: «Datadog - Producción»."
                />
                <.input
                  field={@form[:group_id]}
                  type="select"
                  label="Grupo"
                  options={Enum.map(@groups, fn g -> {g.name, g.id} end)}
                  prompt="Selecciona un grupo"
                  hint="La telemetría de los miembros de este grupo se enviará al webhook."
                />
                <.input
                  field={@form[:url]}
                  type="text"
                  label="URL"
                  hint="Endpoint HTTPS donde se enviarán los datos de telemetría (formato OTLP)."
                />
                <.input
                  field={@form[:headers]}
                  value={headers_to_string(@form[:headers].value)}
                  type="textarea"
                  label="Cabeceras (JSON)"
                  placeholder='{"Authorization": "Bearer xxx"}'
                  hint="Cabeceras HTTP adicionales en formato JSON. Dejalo vacio si no necesitas cabeceras extra."
                />
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-destination-btn">
                    Guardar
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Webhook</th>
                <th>Grupo</th>
                <th>Tipo</th>
                <th>URL</th>
                <th class="text-right">Acciones</th>
              </tr>
            </thead>
            <tbody id="destinations" phx-update="stream">
              <tr
                :for={{id, destination} <- @streams.destinations}
                id={id}
              >
                <td>
                  <div class="flex items-center gap-2">
                    <.icon name="hero-bell-alert" class="w-4 h-4 text-primary shrink-0" />
                    <span class="font-medium text-sm">{destination.name}</span>
                  </div>
                </td>
                <td>
                  <span class="badge badge-sm badge-ghost">
                    {Map.get(@group_names, destination.group_id, "—")}
                  </span>
                </td>
                <td>
                  <span class="badge badge-sm badge-primary/20 border-primary/30 text-primary">
                    {destination.type}
                  </span>
                </td>
                <td class="max-w-xs">
                  <p class="text-xs text-base-content/50 truncate">{destination.url}</p>
                </td>
                <td class="text-right">
                  <div class="flex gap-1 justify-end">
                    <button
                      phx-click="edit_destination"
                      phx-value-id={destination.id}
                      class="btn btn-xs btn-ghost"
                      id={"edit-destination-#{destination.id}"}
                      title="Editar webhook"
                    >
                      <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                    </button>
                    <button
                      phx-click="delete_destination"
                      phx-value-id={destination.id}
                      class="btn btn-xs btn-ghost text-error"
                      id={"delete-destination-#{destination.id}"}
                      data-confirm="¿Eliminar webhook? Esta acción no se puede deshacer."
                      title="Eliminar webhook"
                    >
                      <.icon name="hero-trash" class="w-3.5 h-3.5" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>

          <div :if={@destinations_empty?} class="text-center py-12 text-base-content/40">
            <.icon name="hero-bell-slash" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>No hay webhooks configurados.</p>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    end
    """
  end
end
