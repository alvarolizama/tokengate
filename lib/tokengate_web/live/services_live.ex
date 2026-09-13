defmodule TokengateWeb.ServicesLive do
  @moduledoc """
  Admin-only CRUD for services (API keys sin usuario asociado).

  Listado en tabla compacta (mismo patrón que Users/Groups): búsqueda en
  header, columnas ordenables, stream, y modales para editar, gestionar
  modelos, supervisores y clave API.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Accounts
  alias Tokengate.Accounts.Service
  alias Tokengate.Providers
  alias Tokengate.Providers.{Model, ServiceModel}
  alias Tokengate.Repo

  @sort_columns ~w(name group requests spend inserted_at)a

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
        |> assign(:page_title, "Servicios · Tokengate")
        |> stream_configure(:services, dom_id: &"service-#{&1.id}")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:form, nil)
        |> assign(:editing_service_id, nil)
        |> assign(:new_token, nil)
        |> assign(:detail_service_id, nil)
        |> assign(:models_service_id, nil)
        |> assign(:supervisor_search_service_id, nil)
        |> assign(:supervisor_search_query, "")
        |> assign(:supervisor_search_results, [])
        |> assign(:search_query, "")
        |> assign(:sort_field, :name)
        |> assign(:sort_direction, :asc)
        |> load_services()

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

  # Loads the dataset ONCE per mount (and after mutations). Search/sort
  # filter in-memory over the loaded assigns — zero extra queries.
  defp load_services(socket) do
    services =
      from(s in Service,
        preload: [:api_key, :group],
        order_by: [asc: s.name]
      )
      |> Repo.all()

    groups =
      from(g in Tokengate.Accounts.Group, order_by: [asc: g.name])
      |> Repo.all()

    granted_models =
      from(sma in ServiceModel, select: {sma.service_id, sma.model_id})
      |> Repo.all()
      |> Enum.group_by(fn {service_id, _} -> service_id end, fn {_, model_id} -> model_id end)

    models =
      from(ma in Model, order_by: [asc: ma.name])
      |> Repo.all()

    stats = service_stats(Enum.map(services, & &1.id), socket)

    socket
    |> assign(:all_services, services)
    |> assign(:groups, groups)
    |> assign(:granted_models, granted_models)
    |> assign(:models, models)
    |> assign(:service_stats, stats)
    |> assign(:supervisors_map, build_supervisors_map(Enum.map(services, & &1.id)))
    |> stream_services()
  end

  defp service_stats([], _socket), do: %{}

  defp service_stats(service_ids, socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    thirty_days_ago = Tokengate.Periods.period_bounds("30d", timezone).from

    from(l in Tokengate.Logs.RequestLog,
      where: l.service_id in ^service_ids,
      where: l.inserted_at >= ^thirty_days_ago,
      group_by: l.service_id,
      select: %{
        service_id: l.service_id,
        total_cost: sum(l.provider_cost_usd),
        total_requests: count(l.id),
        total_input_tokens: sum(l.prompt_tokens),
        total_output_tokens: sum(l.completion_tokens),
        avg_latency_ms: avg(l.latency_ms)
      }
    )
    |> Repo.all()
    |> Map.new(fn s -> {s.service_id, s} end)
  end

  # Re-streams the (already loaded) services filtered + sorted. Pure assign
  # work: zero queries.
  defp stream_services(socket) do
    search = socket.assigns[:search_query] || ""
    search_down = String.downcase(search)

    filtered =
      Enum.filter(socket.assigns.all_services, fn s ->
        search == "" or
          String.contains?(String.downcase(s.name), search_down) or
          (s.group && String.contains?(String.downcase(s.group.name), search_down))
      end)

    sorted =
      sort_services(filtered, socket.assigns.sort_field, socket.assigns.sort_direction, socket)

    socket
    |> stream(:services, sorted, reset: true)
    |> assign(:services_empty?, filtered == [])
  end

  defp build_supervisors_map(service_ids) do
    if service_ids == [] do
      %{}
    else
      Repo.all(
        from(ss in Tokengate.Accounts.ServiceSupervisor,
          where: ss.service_id in ^service_ids,
          preload: [:user]
        )
      )
      |> Enum.group_by(& &1.service_id)
    end
  end

  ## Sorting ---------------------------------------------------------------

  defp sort_services(services, field, direction, socket) do
    stats = socket.assigns.service_stats

    Enum.sort_by(
      services,
      fn s -> sort_value(s, field, stats) end,
      fn a, b ->
        if direction == :asc, do: compare_vals(a, b) != :gt, else: compare_vals(a, b) != :lt
      end
    )
  end

  defp sort_value(s, :name, _stats), do: String.downcase(s.name || "")
  defp sort_value(s, :group, _stats), do: String.downcase((s.group && s.group.name) || "")
  defp sort_value(s, :requests, stats), do: stat_value(s, stats, :total_requests)
  defp sort_value(s, :spend, stats), do: stat_value(s, stats, :total_cost)
  defp sort_value(s, :inserted_at, _stats), do: s.inserted_at

  defp stat_value(s, stats, key) do
    case Map.get(stats, s.id) do
      nil -> nil
      stat -> Map.get(stat, key) || Decimal.new(0)
    end
  end

  defp compare_vals(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b)

  defp compare_vals(%DateTime{} = a, %DateTime{} = b) do
    case DateTime.compare(a, b) do
      :lt -> :lt
      :gt -> :gt
      :eq -> :eq
    end
  end

  defp compare_vals(nil, nil), do: :eq
  defp compare_vals(nil, _b), do: :gt
  defp compare_vals(_a, nil), do: :lt

  defp compare_vals(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp compare_vals(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  ## Events — search / sort ------------------------------------------------

  @impl true
  def handle_event("search_services", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> stream_services()}
  end

  def handle_event("sort_services", %{"field" => field}, socket) do
    with {:ok, field} <- to_sort_field(field),
         true <- field in @sort_columns do
      {sort_field, sort_direction} =
        if socket.assigns.sort_field == field do
          {field, toggle_sort_direction(socket.assigns.sort_direction)}
        else
          {field, default_direction_for(field)}
        end

      {:noreply,
       socket
       |> assign(:sort_field, sort_field)
       |> assign(:sort_direction, sort_direction)
       |> stream_services()}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Events — service CRUD --------------------------------------------------

  def handle_event("new_service", _params, socket) do
    changeset = Accounts.change_service(%Service{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :service))
     |> assign(:editing_service_id, :new)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_service_id, nil)}
  end

  def handle_event("edit_service", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)
    changeset = Accounts.change_service(service)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :service))
     |> assign(:editing_service_id, service.id)}
  end

  def handle_event("save_service", %{"service" => service_params}, socket) do
    save_service(socket, socket.assigns.editing_service_id, service_params)
  end

  def handle_event("delete_service", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)

    case Accounts.delete_service(service) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Servicio eliminado.")
         |> load_services()}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field} #{message}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, "No se pudo eliminar: #{msg}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el servicio.")}
    end
  end

  ## Events — detail / models modals ---------------------------------------

  def handle_event("view_detail", %{"id" => service_id}, socket) do
    {:noreply, assign(socket, :detail_service_id, service_id)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :detail_service_id, nil)}
  end

  def handle_event("edit_models", %{"id" => service_id}, socket) do
    {:noreply, assign(socket, :models_service_id, service_id)}
  end

  def handle_event("close_models", _params, socket) do
    {:noreply, assign(socket, :models_service_id, nil)}
  end

  ## Events — API key management -----------------------------------------

  def handle_event("generate_key", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)

    case Accounts.generate_service_api_key(service) do
      {:ok, _api_key, new_token} ->
        {:noreply,
         socket
         |> assign(:new_token, new_token)
         |> put_flash(:info, "Clave generada correctamente.")
         |> load_services()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo generar la clave.")}
    end
  end

  def handle_event("revoke_key", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)

    service =
      if service.api_key do
        Repo.preload(service, :api_key)
      else
        service
      end

    case service.api_key do
      nil ->
        {:noreply, put_flash(socket, :error, "Este servicio no tiene clave.")}

      api_key ->
        case Accounts.revoke_service_api_key(api_key) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Clave revocada.")
             |> load_services()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
        end
    end
  end

  def handle_event("dismiss_new_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  ## Events — model grants ------------------------------------------------

  def handle_event("toggle_model", %{"target-id" => service_id, "model-id" => model_id}, socket) do
    service_alias_ids = Map.get(socket.assigns.granted_models, service_id, [])

    result =
      if model_id in service_alias_ids do
        Providers.revoke_model_from_service(service_id, model_id)
      else
        Providers.grant_model_to_service(service_id, model_id)
      end

    case result do
      {:ok, _} ->
        # Surgical refresh: only granted_models changes here.
        granted_models =
          from(sma in ServiceModel, select: {sma.service_id, sma.model_id})
          |> Repo.all()
          |> Enum.group_by(fn {sid, _} -> sid end, fn {_, mid} -> mid end)

        {:noreply,
         socket
         |> put_flash(:info, "Modelos actualizados.")
         |> assign(:granted_models, granted_models)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar el modelo.")}
    end
  end

  ## Events — supervisor management -----------------------------------------

  def handle_event("toggle_supervisor_form", %{"service-id" => service_id}, socket) do
    open? = socket.assigns.supervisor_search_service_id == service_id

    new_id = if open?, do: nil, else: service_id

    {:noreply,
     socket
     |> assign(:supervisor_search_service_id, new_id)
     |> assign(:supervisor_search_query, "")
     |> assign(:supervisor_search_results, [])}
  end

  def handle_event("search_supervisor_users", %{"value" => query}, socket) do
    results =
      if is_binary(query) and String.trim(query) != "" do
        service_id = socket.assigns.supervisor_search_service_id
        supervisor_ids = service_supervisor_user_ids(socket, service_id)

        query
        |> String.trim()
        |> Accounts.search_users(25)
        |> Enum.reject(fn user -> user.id in supervisor_ids end)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:supervisor_search_query, query || "")
     |> assign(:supervisor_search_results, results)}
  end

  def handle_event("add_supervisor", %{"service-id" => service_id, "user-id" => user_id}, socket) do
    case Accounts.add_service_supervisor(service_id, user_id) do
      {:ok, _supervisor} ->
        {:noreply,
         socket
         |> put_flash(:info, "Supervisor agregado.")
         |> assign(:supervisor_search_results, [])
         |> assign(:supervisor_search_query, "")
         |> load_services()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo agregar el supervisor.")}
    end
  end

  def handle_event(
        "remove_supervisor",
        %{"service-id" => service_id, "user-id" => user_id},
        socket
      ) do
    case Accounts.remove_service_supervisor(service_id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Supervisor removido.")
         |> load_services()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo remover el supervisor.")}
    end
  end

  defp service_supervisor_user_ids(socket, service_id) do
    case Map.get(socket.assigns.supervisors_map, service_id, []) do
      list when is_list(list) -> Enum.map(list, & &1.user_id)
      _ -> []
    end
  end

  ## Private helpers — save ----------------------------------------------

  defp save_service(socket, :new, service_params) do
    case Accounts.create_service(service_params) do
      {:ok, _service} ->
        {:noreply,
         socket
         |> put_flash(:info, "Servicio creado.")
         |> assign(:form, nil)
         |> assign(:editing_service_id, nil)
         |> load_services()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :service))}
    end
  end

  defp save_service(socket, service_id, service_params) when is_binary(service_id) do
    service = Accounts.get_service!(service_id)

    case Accounts.update_service(service, service_params) do
      {:ok, _service} ->
        {:noreply,
         socket
         |> put_flash(:info, "Servicio actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_service_id, nil)
         |> load_services()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :service))}
    end
  end

  ## Template helpers -----------------------------------------------------

  defp to_sort_field(field) when is_binary(field) do
    {:ok, String.to_existing_atom(field)}
  rescue
    ArgumentError -> :error
  end

  defp toggle_sort_direction(:asc), do: :desc
  defp toggle_sort_direction(:desc), do: :asc

  # Numeric columns start desc (biggest spenders / most requests first).
  defp default_direction_for(field) when field in [:requests, :spend, :inserted_at], do: :desc
  defp default_direction_for(_), do: :asc

  def granted_alias_ids(granted_models, service_id) do
    Map.get(granted_models, service_id, [])
  end

  def format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  def format_decimal(nil), do: "—"
  def format_decimal(value), do: to_string(value)

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(%Decimal{} = d),
    do: d |> Decimal.round(0) |> Decimal.to_string() |> format_number()

  def format_number(nil), do: "0"
  def format_number(n), do: to_string(n)

  def key_status_badge("active"), do: "badge-success"
  def key_status_badge(_), do: "badge-error"

  defp stats_for(assigns, service_id) do
    Map.get(
      assigns.service_stats,
      service_id,
      %{total_cost: nil, total_requests: 0, total_input_tokens: 0, total_output_tokens: 0}
    )
  end

  defp detail_service(assigns) do
    Enum.find(assigns.all_services, &(&1.id == assigns.detail_service_id))
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Servicios
          <:subtitle>API keys para servicios sin usuario asociado</:subtitle>
          <:actions>
            <div class="flex items-center gap-3">
              <.form
                for={%{}}
                phx-change="search_services"
                phx-submit="search_services"
                id="search-form"
              >
                <div class="relative">
                  <.icon
                    name="hero-magnifying-glass"
                    class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
                  />
                  <input
                    type="text"
                    name="q"
                    placeholder="Buscar por nombre o grupo..."
                    value={@search_query}
                    phx-debounce="300"
                    class="input input-sm input-bordered pl-9 w-64"
                    id="service-search"
                  />
                </div>
              </.form>
              <.button phx-click="new_service" id="new-service-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> Nuevo servicio
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- New token banner --%>
        <div :if={@new_token} class="alert alert-success" id="new-token-banner">
          <.icon name="hero-key" class="w-5 h-5 shrink-0" />
          <div>
            <p class="font-semibold">Clave generada</p>
            <p class="text-sm opacity-80">Cópiala ahora, no se volverá a mostrar.</p>
            <code class="block mt-2 p-2 bg-black/10 rounded text-sm font-mono break-all">
              {@new_token}
            </code>
          </div>
          <button phx-click="dismiss_new_token" class="btn btn-ghost btn-sm">Cerrar</button>
        </div>

        <%!-- Service form (create / edit) — modal --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_service_id == :new, do: "Nuevo servicio", else: "Editar servicio"}
              </h2>
              <.form for={@form} id="service-form" phx-submit="save_service">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Nombre"
                  hint={"Nombre identificativo del servicio. Ej.: \"Bot de Telegram\", \"Webhook de Shopify\"."}
                />
                <div class="mt-3">
                  <.input
                    field={@form[:group_id]}
                    type="select"
                    label="Grupo"
                    options={Enum.map(@groups, &{&1.name, &1.id})}
                    hint="Grupo del que hereda catálogo, presupuesto y límites."
                  />
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 mt-3">
                  <.input
                    field={@form[:monthly_budget_usd]}
                    type="number"
                    label="Budget extra (USD/mes)"
                    step="any"
                    hint="Extra sobre el default del grupo. Vacío = solo el default."
                  />
                  <.input
                    field={@form[:concurrency_limit]}
                    type="number"
                    label="Concurrencia extra"
                    hint="Extra sobre el default del grupo."
                  />
                  <.input
                    field={@form[:rpm_limit]}
                    type="number"
                    label="RPM extra"
                    hint="Extra sobre el default del grupo."
                  />
                </div>
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-service-btn">Guardar</button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Models modal — manage model grants per service --%>
        <div
          :if={@models_service_id}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id={"models-modal-#{@models_service_id}"}
        >
          <div class="absolute inset-0 bg-black/50" phx-click="close_models" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">Modelos del servicio</h2>
              <.model_picker
                id={"model-picker-#{@models_service_id}"}
                models={@models}
                granted_ids={granted_alias_ids(@granted_models, @models_service_id)}
                toggle_event="toggle_model"
                target_value={@models_service_id}
                empty_text="No hay modelos disponibles."
              />
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

        <%!-- Detail modal — stats + API key + supervisores --%>
        <div
          :if={@detail_service_id && detail_service(assigns)}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id="service-detail-modal"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="close_detail" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {detail_service(assigns).name}
                <span class="text-sm text-base-content/50 font-normal">
                  · Grupo: {detail_service(assigns).group && detail_service(assigns).group.name}
                </span>
              </h2>

              <%!-- Stats 30d --%>
              <% stats = stats_for(assigns, @detail_service_id) %>
              <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Gasto real</span>
                    <p class="text-lg font-bold">${format_decimal(stats.total_cost)}</p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Requests</span>
                    <p class="text-lg font-bold">{format_number(stats.total_requests)}</p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Tokens In</span>
                    <p class="text-lg font-bold">{format_number(stats.total_input_tokens)}</p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Tokens Out</span>
                    <p class="text-lg font-bold">{format_number(stats.total_output_tokens)}</p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>
              </div>

              <%!-- API key --%>
              <div class="mt-4 p-3 bg-base-200 rounded-lg">
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-sm font-medium">API Key</p>
                    <%= if detail_service(assigns).api_key do %>
                      <p class="text-xs text-base-content/60">
                        <span class="font-mono">{detail_service(assigns).api_key.key_prefix}</span>…
                        <span class={[
                          "badge badge-xs",
                          key_status_badge(detail_service(assigns).api_key.status)
                        ]}>
                          {detail_service(assigns).api_key.status}
                        </span>
                      </p>
                    <% else %>
                      <p class="text-xs text-base-content/40">Sin clave</p>
                    <% end %>
                  </div>
                  <div class="flex gap-1">
                    <button
                      phx-click="generate_key"
                      phx-value-id={@detail_service_id}
                      class="btn btn-primary btn-xs"
                      title={
                        if detail_service(assigns).api_key,
                          do: "Regenerar clave",
                          else: "Generar clave"
                      }
                    >
                      <.icon name="hero-key" class="w-4 h-4" />
                      {if detail_service(assigns).api_key, do: "Regenerar", else: "Generar"}
                    </button>
                    <%= if detail_service(assigns).api_key && detail_service(assigns).api_key.status == "active" do %>
                      <button
                        phx-click="revoke_key"
                        phx-value-id={@detail_service_id}
                        data-confirm="¿Revocar esta clave? El servicio dejará de funcionar inmediatamente."
                        class="btn btn-error btn-xs"
                        title="Revocar clave"
                      >
                        <.icon name="hero-no-symbol" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Supervisores --%>
              <% supervisors = Map.get(@supervisors_map, @detail_service_id, []) %>
              <div class="mt-4 p-3 bg-base-200 rounded-lg">
                <div class="flex items-center justify-between mb-2">
                  <div>
                    <p class="text-sm font-medium">Supervisores</p>
                    <p class="text-xs text-base-content/60">
                      Ven sus servicios asignados en <code>/dashboard/services/supervised</code>
                      (solo lectura).
                    </p>
                  </div>
                  <button
                    phx-click="toggle_supervisor_form"
                    phx-value-service-id={@detail_service_id}
                    class="btn btn-ghost btn-xs"
                  >
                    {if @supervisor_search_service_id == @detail_service_id,
                      do: "Cerrar",
                      else: "Agregar supervisor"}
                  </button>
                </div>

                <div :if={supervisors == []} class="text-xs text-base-content/40">
                  Sin supervisores asignados.
                </div>

                <div :if={supervisors != []} class="flex flex-wrap gap-2">
                  <span
                    :for={supervisor <- supervisors}
                    class="badge badge-primary badge-sm gap-1"
                    id={"supervisor-#{supervisor.user_id}"}
                  >
                    <span>
                      {(supervisor.user && (supervisor.user.name || supervisor.user.email)) ||
                        supervisor.user_id}
                    </span>
                    <button
                      type="button"
                      phx-click="remove_supervisor"
                      phx-value-service-id={@detail_service_id}
                      phx-value-user-id={supervisor.user_id}
                      class="ml-1 leading-none opacity-70 hover:opacity-100"
                      title="Quitar supervisor"
                      aria-label="Quitar supervisor"
                    >
                      ×
                    </button>
                  </span>
                </div>

                <div :if={@supervisor_search_service_id == @detail_service_id} class="mt-3">
                  <.input
                    type="text"
                    name="supervisor_query"
                    value={@supervisor_search_query}
                    placeholder="Buscar por email o nombre…"
                    phx-keyup="search_supervisor_users"
                    phx-change="search_supervisor_users"
                    id="supervisor-search"
                  />
                  <div
                    :if={@supervisor_search_query != "" and @supervisor_search_results == []}
                    class="text-xs text-base-content/40 mt-2"
                  >
                    Sin coincidencias.
                  </div>
                  <div
                    :if={@supervisor_search_results != []}
                    class="mt-2 max-h-48 overflow-y-auto border border-base-300 rounded-md"
                  >
                    <button
                      :for={user <- @supervisor_search_results}
                      type="button"
                      phx-click="add_supervisor"
                      phx-value-service-id={@detail_service_id}
                      phx-value-user-id={user.id}
                      class="w-full text-left px-3 py-2 text-sm hover:bg-base-100 border-b border-base-300 last:border-b-0"
                    >
                      <div class="font-medium">{user.name || user.email}</div>
                      <div class="text-xs text-base-content/60">{user.email}</div>
                    </button>
                  </div>
                </div>
              </div>

              <div class="flex gap-2 mt-4 justify-end">
                <button
                  type="button"
                  phx-click="close_detail"
                  class="btn btn-primary btn-sm"
                  id="close-detail-btn"
                >
                  Cerrar
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Services table --%>
        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>
                  <.sort_button
                    field={:name}
                    label="Servicio"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>
                  <.sort_button
                    field={:group}
                    label="Grupo"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th class="text-right">
                  <.sort_button
                    field={:requests}
                    label="Requests 30d"
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th class="text-right">
                  <.sort_button
                    field={:spend}
                    label="Gasto 30d"
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th>Modelos</th>
                <th>API Key</th>
                <th>
                  <.sort_button
                    field={:inserted_at}
                    label="Creado"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th></th>
              </tr>
            </thead>
            <tbody id="services" phx-update="stream">
              <tr :for={{id, service} <- @streams.services} id={id}>
                <.service_row
                  service={service}
                  granted_models={@granted_models}
                  stats={@service_stats}
                  supervisors_map={@supervisors_map}
                  timezone={@timezone}
                />
              </tr>
            </tbody>
          </table>
          <div
            :if={@services_empty?}
            class="text-center py-12 text-base-content/40"
            id="services-empty"
          >
            <.icon name="hero-wrench-screwdriver" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>No hay servicios todavía.</p>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Components ---------------------------------------------------------------

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :current, :atom, required: true
  attr :direction, :atom, required: true
  attr :align, :string, default: "left"

  defp sort_button(assigns) do
    ~H"""
    <button
      phx-click="sort_services"
      phx-value-field={@field}
      class={["flex items-center gap-1 hover:text-primary", @align == "right" && "justify-end w-full"]}
      id={"sort-#{@field}"}
    >
      {@label}
      <span class="inline-block w-3 text-center">
        <%= if @current == @field do %>
          {if @direction == :asc, do: "▲", else: "▼"}
        <% end %>
      </span>
    </button>
    """
  end

  attr :service, :map, required: true
  attr :granted_models, :map, required: true
  attr :stats, :map, required: true
  attr :supervisors_map, :map, required: true
  attr :timezone, :string, required: true

  defp service_row(assigns) do
    ~H"""
    <td>
      <div class="flex items-center gap-3">
        <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-base-200 shrink-0">
          <.icon name="hero-wrench-screwdriver" class="w-4 h-4 text-base-content/60" />
        </div>
        <div class="min-w-0">
          <p class="font-medium text-sm truncate">{@service.name}</p>
          <p class="text-xs text-base-content/50">
            +{format_decimal(@service.monthly_budget_usd)} USD/mes · +{@service.concurrency_limit} conc. ·
            +{@service.rpm_limit} RPM
          </p>
        </div>
      </div>
    </td>
    <td class="text-sm">
      {(@service.group && @service.group.name) || "—"}
    </td>
    <td class="text-right text-xs font-mono">
      {format_number(stat_for(@stats, @service.id, :total_requests))}
    </td>
    <td class="text-right text-xs font-mono">
      ${format_decimal(stat_decimal(@stats, @service.id, :total_cost))}
    </td>
    <td>
      <button
        phx-click="edit_models"
        phx-value-id={@service.id}
        class="badge badge-sm badge-outline gap-1 hover:badge-primary transition-colors cursor-pointer"
        id={"edit-models-#{@service.id}"}
        title="Gestionar modelos del servicio"
      >
        <.icon name="hero-rectangle-stack" class="w-3 h-3" />
        {length(Map.get(@granted_models, @service.id, []))} modelos
      </button>
    </td>
    <td>
      <%= case @service.api_key do %>
        <% nil -> %>
          <span class="text-xs text-base-content/30">Sin clave</span>
        <% api_key -> %>
          <div class="flex items-center gap-1">
            <span class="text-xs font-mono">{api_key.key_prefix}…</span>
            <span class={["badge badge-xs", key_status_badge(api_key.status)]}>{api_key.status}</span>
          </div>
      <% end %>
    </td>
    <td class="text-xs text-base-content/50">
      {format_date(@service.inserted_at, @timezone)}
    </td>
    <td>
      <div class="flex gap-1">
        <button
          phx-click="view_detail"
          phx-value-id={@service.id}
          class="btn btn-xs btn-ghost"
          id={"detail-#{@service.id}"}
          title="Ver detalle: stats, clave y supervisores"
        >
          <.icon name="hero-eye" class="w-3 h-3" />
        </button>
        <button
          phx-click="edit_service"
          phx-value-id={@service.id}
          class="btn btn-xs btn-ghost"
          id={"edit-#{@service.id}"}
          title="Editar"
        >
          <.icon name="hero-pencil" class="w-3 h-3" />
        </button>
        <button
          phx-click="delete_service"
          phx-value-id={@service.id}
          data-confirm="¿Eliminar este servicio? Se perderán la clave y los modelos."
          class="btn btn-xs btn-ghost text-error"
          id={"delete-#{@service.id}"}
          title="Eliminar"
        >
          <.icon name="hero-trash" class="w-3 h-3" />
        </button>
      </div>
    </td>
    """
  end

  defp stat_for(stats, service_id, key) do
    case Map.get(stats, service_id) do
      nil -> 0
      stat -> Map.get(stat, key) || 0
    end
  end

  defp stat_decimal(stats, service_id, key) do
    case Map.get(stats, service_id) do
      nil -> nil
      stat -> Map.get(stat, key)
    end
  end
end
