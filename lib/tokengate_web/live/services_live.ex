defmodule TokengateWeb.ServicesLive do
  @moduledoc """
  Admin-only CRUD for services (API keys sin usuario asociado).

  Listado en tabla compacta (mismo patrón que Users/Groups): búsqueda en
  header, columnas ordenables, stream, y modales para editar, gestionar
  modelos, supervisores y clave API.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  import TokengateWeb.AdminComponents
  import TokengateWeb.KeysPanel
  import TokengateWeb.StatsHelpers, only: [budget_cell: 1, format_usd: 1]
  alias Tokengate.Accounts
  alias Tokengate.Accounts.Service
  alias Tokengate.Budgets
  alias Tokengate.Credits
  alias Tokengate.Logs
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Providers
  alias Tokengate.Providers.{Model, ServiceModel}
  alias Tokengate.Repo

  @sort_columns ~w(name limit requests monthly_spend total_spend inserted_at)a

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user.global_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to access this section."))
       |> redirect(to: "/dashboard")}
    else
      socket =
        socket
        |> assign(:page_title, gettext("Services") <> " · Tokengate")
        |> stream_configure(:services, dom_id: &"service-#{&1.id}")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:form, nil)
        |> assign(:editing_service_id, nil)
        |> assign(:new_token, nil)
        |> assign(:keys_service_id, nil)
        |> assign(:keys_service_name, nil)
        |> assign(:keys, [])
        |> assign(:keys_spend, %{})
        |> assign(:keys_by_service, %{})
        |> assign(:delete_target_id, nil)
        |> assign(:delete_target_name, nil)
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
        order_by: [asc: s.name]
      )
      |> Repo.all()

    service_ids = Enum.map(services, & &1.id)

    granted_models =
      from(sma in ServiceModel, select: {sma.service_id, sma.model_id})
      |> Repo.all()
      |> Enum.group_by(fn {service_id, _} -> service_id end, fn {_, model_id} -> model_id end)

    models =
      from(ma in Model, order_by: [asc: ma.name])
      |> Repo.all()

    stats = service_stats(Enum.map(services, & &1.id), socket)
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    # Gasto mensual / total por servicio — mismas columnas que la tabla de
    # Usuarios. Agregados whole-table cacheados (5s TTL) para no re-escanear
    # request_logs en cada keystroke de búsqueda/orden.
    monthly_spend =
      DashboardCache.fetch_or_compute({:services_monthly_spend, timezone}, fn ->
        Budgets.spend_by_service()
      end)

    # Techo de cada servicio + consumo debitado (el mismo par
    # consumido/techo que la columna de Usuarios). Agregado whole-table
    # cacheado (5s TTL) igual que el resto de la tabla.
    service_credit =
      DashboardCache.fetch_or_compute({:services_credit}, fn ->
        Credits.service_summaries(services)
      end)

    total_spend =
      DashboardCache.fetch_or_compute({:services_total_spend}, fn ->
        Logs.total_spend_by_service()
      end)

    socket
    |> assign(:all_services, services)
    |> assign(:granted_models, granted_models)
    |> assign(:models, models)
    |> assign(:service_stats, stats)
    |> assign(:monthly_spend_by_service, monthly_spend)
    |> assign(:service_credit, service_credit)
    |> assign(:total_spend_by_service, total_spend)
    |> assign(:supervisors_map, build_supervisors_map(Enum.map(services, & &1.id)))
    |> assign(:keys_by_service, Accounts.list_api_keys_for_services(service_ids))
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
          String.contains?(String.downcase(limit_search_text(s)), search_down)
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
    ctx = %{
      stats: socket.assigns.service_stats,
      monthly_spend: socket.assigns.monthly_spend_by_service,
      total_spend: socket.assigns.total_spend_by_service
    }

    Enum.sort_by(
      services,
      fn s -> {sort_value(s, field, ctx), String.downcase(s.name || "")} end,
      fn {val_a, name_a}, {val_b, name_b} ->
        case compare_sort_values(val_a, val_b, direction) do
          :eq -> compare_sort_values(name_a, name_b, :asc) != :gt
          order -> order == :lt
        end
      end
    )
  end

  defp sort_value(s, :limit, _ctx), do: limit_search_text(s)
  defp sort_value(s, :name, _ctx), do: String.downcase(s.name || "")

  defp sort_value(s, :requests, ctx), do: stat_value(s, ctx.stats, :total_requests)
  defp sort_value(s, :monthly_spend, ctx), do: Map.get(ctx.monthly_spend, s.id)
  defp sort_value(s, :total_spend, ctx), do: Map.get(ctx.total_spend, s.id)
  defp sort_value(s, :inserted_at, _ctx), do: s.inserted_at

  defp stat_value(s, stats, key) do
    case Map.get(stats, s.id) do
      nil -> nil
      stat -> Map.get(stat, key) || Decimal.new(0)
    end
  end

  defp limit_search_text(%{unlimited_spend: true}), do: "ilimitado"

  defp limit_search_text(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: Decimal.to_string(limit)

  defp limit_search_text(_), do: String.downcase(gettext("No budget"))

  defp compare_vals(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b)

  # Calendar structs: term order compares the struct as a map — day before
  # month/year — so a column that hands one over would read as unsorted. Each
  # module's own compare/2 is the chronological one.
  defp compare_vals(%mod{} = a, %mod{} = b) when mod in [DateTime, NaiveDateTime, Date],
    do: mod.compare(a, b)

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

  # Sin dato (nil) va SIEMPRE al final, en ambas direcciones: el listado pinta
  # $0.00 en esas celdas, así que no pueden encabezar un "de mayor a menor".
  # :lt/:gt/:eq para poder desempatar por el nombre.
  defp compare_sort_values(nil, nil, _direction), do: :eq
  defp compare_sort_values(nil, _b, _direction), do: :gt
  defp compare_sort_values(_a, nil, _direction), do: :lt

  defp compare_sort_values(a, b, direction) do
    case {compare_vals(a, b), direction} do
      {:eq, _} -> :eq
      {:lt, :asc} -> :lt
      {:lt, :desc} -> :gt
      {:gt, :asc} -> :gt
      {:gt, :desc} -> :lt
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

  # La confirmación la dibuja el assign (la primitiva <.modal> se gatea con
  # `:if`): no hay diálogo escondido en el DOM esperando un push del cliente.
  def handle_event("open_delete_modal", %{"id" => service_id, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(:delete_target_id, service_id)
     |> assign(:delete_target_name, name)}
  end

  # Cerrar la confirmación (✕, Escape o click-away) olvida el objetivo.
  def handle_event("cancel_delete", _params, socket) do
    {:noreply,
     socket
     |> assign(:delete_target_id, nil)
     |> assign(:delete_target_name, nil)}
  end

  def handle_event("delete_service", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)

    case Accounts.delete_service(service) do
      {:ok, _} ->
        audit(socket, "service.delete", "service", service.id, %{"name" => service.name})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Service deleted."))
         |> assign(:delete_target_id, nil)
         |> assign(:delete_target_name, nil)
         |> load_services()}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field} #{message}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, gettext("Could not delete: %{reason}", reason: msg))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the service."))}
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

  ## Events — API keys (N keys con etiqueta, igual que un usuario) ---------

  # Las claves de un servicio se cargan solo al abrir su panel: el listado no
  # paga N+1 por cada fila.
  def handle_event("manage_keys", %{"id" => service_id}, socket) do
    case Accounts.get_service(service_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Service not found."))}

      service ->
        {:noreply,
         socket
         |> assign(:keys_service_id, service.id)
         |> assign(:keys_service_name, service.name)
         |> assign(:new_token, nil)
         |> load_service_keys(service.id)}
    end
  end

  def handle_event("cancel_manage_keys", _params, socket) do
    {:noreply,
     socket
     |> assign(:keys_service_id, nil)
     |> assign(:keys_service_name, nil)
     |> assign(:keys, [])
     |> assign(:keys_spend, %{})
     |> assign(:new_token, nil)}
  end

  def handle_event("create_service_key", %{"key" => key_params}, socket) do
    service_id = socket.assigns.keys_service_id

    if service_id do
      {token, key_hash, key_prefix} = Accounts.generate_api_key_material()

      attrs = %{
        "subject_type" => "service",
        "service_id" => service_id,
        "label" => String.trim(key_params["label"] || ""),
        "key_hash" => key_hash,
        "key_prefix" => key_prefix,
        "status" => "active"
      }

      attrs = if attrs["label"] == "", do: Map.delete(attrs, "label"), else: attrs

      case Accounts.create_api_key(attrs) do
        {:ok, api_key} ->
          audit(socket, "api_key.create", "api_key", api_key.id, %{
            "label" => api_key.label,
            "service_id" => service_id
          })

          {:noreply,
           socket
           |> assign(:new_token, token)
           |> put_flash(:info, gettext("Key created. Copy it now: it is not shown again."))
           |> load_service_keys(service_id)
           |> load_services()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create the key."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke_service_key", %{"key-id" => api_key_id}, socket) do
    with %{} = api_key <- Accounts.get_service_api_key(api_key_id),
         true <- api_key.service_id == socket.assigns.keys_service_id do
      case Accounts.revoke_service_api_key(api_key) do
        {:ok, _} ->
          audit(socket, "api_key.revoke", "api_key", api_key.id, %{
            "label" => api_key.label,
            "service_id" => api_key.service_id
          })

          {:noreply,
           socket
           |> put_flash(:info, gettext("Key revoked."))
           |> load_service_keys(socket.assigns.keys_service_id)
           |> load_services()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not revoke the key."))}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Key not found."))}
    end
  end

  def handle_event("dismiss_new_key_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  # Limpia las sticky routes del SERVICIO (todas sus keys): su próxima petición
  # re-evalúa proveedores en vez de quedarse pegado a uno degradado.
  def handle_event("clear_service_sticky_routes", %{"id" => service_id}, socket) do
    case Accounts.get_service(service_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Service not found."))}

      service ->
        Accounts.clear_service_sticky_routes(service_id)

        audit(socket, "routing.clear_sticky", "service", service_id, %{"name" => service.name})

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Sticky routes cleared for %{who}. Their next request will be re-routed.",
             who: service.name
           )
         )
         |> load_service_keys(service_id)}
    end
  end

  ## Events — model grants ------------------------------------------------

  def handle_event("toggle_model", %{"target-id" => service_id, "model-id" => model_id}, socket) do
    service_alias_ids = Map.get(socket.assigns.granted_models, service_id, [])

    granted? = model_id not in service_alias_ids

    result =
      if granted? do
        Providers.grant_model_to_service(service_id, model_id)
      else
        Providers.revoke_model_from_service(service_id, model_id)
      end

    case result do
      {:ok, _} ->
        audit(socket, "service.model_access_toggle", "service", service_id, %{
          "model_id" => model_id,
          "granted" => granted?
        })

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
        {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
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
        audit(socket, "service_supervisor.add", "service", service_id, %{"user_id" => user_id})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Supervisor added."))
         |> assign(:supervisor_search_results, [])
         |> assign(:supervisor_search_query, "")
         |> load_services()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not add the supervisor."))}
    end
  end

  def handle_event(
        "remove_supervisor",
        %{"service-id" => service_id, "user-id" => user_id},
        socket
      ) do
    case Accounts.remove_service_supervisor(service_id, user_id) do
      {:ok, _} ->
        audit(socket, "service_supervisor.remove", "service", service_id, %{"user_id" => user_id})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Supervisor removed."))
         |> load_services()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the supervisor."))}
    end
  end

  defp service_supervisor_user_ids(socket, service_id) do
    case Map.get(socket.assigns.supervisors_map, service_id, []) do
      list when is_list(list) -> Enum.map(list, & &1.user_id)
      _ -> []
    end
  end

  ## Private helpers — save ----------------------------------------------

  # Keys activas del servicio + consumo por key, cargadas solo al abrir el panel.
  defp load_service_keys(socket, service_id) do
    keys = Accounts.list_api_keys_for_service(service_id)
    spend = Accounts.spend_by_api_key(Enum.map(keys, & &1.id))

    socket
    |> assign(:keys, keys)
    |> assign(:keys_spend, spend)
  end

  defp save_service(socket, :new, service_params) do
    case Accounts.create_service(service_params) do
      {:ok, service} ->
        audit(socket, "service.create", "service", service.id, %{"name" => service.name})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Service created."))
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
      {:ok, updated} ->
        audit(socket, "service.update", "service", updated.id, %{
          "name" => updated.name,
          "changes" =>
            Map.take(service_params, [
              "name",
              "status",
              "default_concurrency_limit",
              "default_rpm_limit"
            ])
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Service updated."))
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
  defp default_direction_for(field)
       when field in [:requests, :monthly_spend, :total_spend, :inserted_at],
       do: :desc

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

  # Sub label for display: name, or "Ilimitado" when the service has no
  defp limit_label(%{unlimited_spend: true}), do: "Ilimitado"

  defp limit_label(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: "$#{Decimal.to_string(limit)}/mes"

  defp limit_label(_service), do: gettext("No budget")

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
          {gettext("Services")}
          <:subtitle>{gettext("API keys for services without an associated user")}</:subtitle>
          <:actions>
            <div class="flex items-center gap-3">
              <.admin_search
                event="search_services"
                value={@search_query}
                placeholder={gettext("Search by name or limit profile…")}
                input_id="service-search"
              />
              <.button phx-click="new_service" id="new-service-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> Nuevo servicio
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- Service form (create / edit) — modal --%>
        <.modal
          :if={@form}
          id="service-form-modal"
          title={
            if @editing_service_id == :new, do: gettext("New service"), else: gettext("Edit service")
          }
          on_close="cancel_form"
        >
          <.form for={@form} id="service-form" phx-submit="save_service">
            <.input
              field={@form[:name]}
              type="text"
              label={gettext("Name")}
              hint={
                gettext(
                  "Identifying name of the service, e.g. \"Telegram bot\" or \"Shopify webhook\"."
                )
              }
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mt-3">
              <.input
                field={@form[:monthly_spend_limit_usd]}
                type="number"
                step="0.01"
                min="0"
                label={gettext("Monthly cap (USD)")}
                hint={gettext("0 = zero spend. Empty = no budget (top-ups only).")}
              />
              <.input
                field={@form[:unlimited_spend]}
                type="checkbox"
                label="Ilimitado"
                hint={gettext("The only path to unlimited; it wins over the cap.")}
              />
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 mt-3">
              <.input
                field={@form[:concurrency_limit]}
                type="number"
                label={gettext("Concurrency")}
                hint={gettext("Absolute cap (defaults to 5 when empty).")}
              />
              <.input
                field={@form[:rpm_limit]}
                type="number"
                label="RPM"
                hint={gettext("Absolute cap (defaults to 60 when empty).")}
              />
            </div>
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">{gettext(
                "Cancel"
              )}</button>
              <button type="submit" class="btn btn-primary btn-sm" id="save-service-btn">{gettext(
                "Save"
              )}</button>
            </div>
          </.form>
        </.modal>

        <%!-- Keys modal — N claves con etiqueta (mismo panel que Usuarios) --%>
        <.modal
          :if={@keys_service_id}
          id="service-keys-modal"
          title={gettext("API keys of %{name}", name: @keys_service_name)}
          on_close="cancel_manage_keys"
          max_w="max-w-2xl"
        >
          <p class="text-xs text-base-content/50 mb-4">
            {gettext("A service can have several active keys, each with its own label.")}
          </p>

          <.keys_panel
            subject_kind="service"
            subject_id={@keys_service_id}
            keys={@keys}
            spend={@keys_spend}
            new_token={@new_token}
            create_event="create_service_key"
            revoke_event="revoke_service_key"
            dismiss_event="dismiss_new_key_token"
            sticky_event="clear_service_sticky_routes"
            empty_text={gettext("This service has no active keys.")}
          />

          <div class="flex gap-2 mt-4 justify-end">
            <button type="button" phx-click="cancel_manage_keys" class="btn btn-ghost btn-sm">
              {gettext("Close")}
            </button>
          </div>
        </.modal>

        <%!-- Models modal — manage model grants per service --%>
        <.modal
          :if={@models_service_id}
          id="models-modal-#{@models_service_id}"
          title={gettext("Service models")}
          on_close="close_models"
        >
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
              {gettext("Done")}
            </button>
          </div>
        </.modal>

        <%!-- Detail modal — stats + supervisores (las claves viven en su propio modal) --%>
        <.modal
          :if={@detail_service_id && detail_service(assigns)}
          id="service-detail-modal"
          title={detail_service(assigns).name}
          on_close="close_detail"
          max_w="max-w-2xl"
        >
          <%!-- El límite del servicio viajaba en el título del modal; con el
               título de la primitiva <.modal> va como caption del cuerpo. --%>
          <p class="text-xs text-base-content/50 mb-4">
            · Límite: {limit_label(detail_service(assigns))}
          </p>

          <%!-- Stats 30d --%>
          <% stats = stats_for(assigns, @detail_service_id) %>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4">
                <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">{gettext(
                  "Actual spend"
                )}</span>
                <p class="text-lg font-bold">${format_decimal(stats.total_cost)}</p>
                <p class="text-xs text-base-content/40">{gettext("30 days")}</p>
              </div>
            </div>
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4">
                <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Requests</span>
                <p class="text-lg font-bold">{format_number(stats.total_requests)}</p>
                <p class="text-xs text-base-content/40">{gettext("30 days")}</p>
              </div>
            </div>
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4">
                <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Tokens In</span>
                <p class="text-lg font-bold">{format_number(stats.total_input_tokens)}</p>
                <p class="text-xs text-base-content/40">{gettext("30 days")}</p>
              </div>
            </div>
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4">
                <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Tokens Out</span>
                <p class="text-lg font-bold">{format_number(stats.total_output_tokens)}</p>
                <p class="text-xs text-base-content/40">{gettext("30 days")}</p>
              </div>
            </div>
          </div>

          <%!-- Supervisores --%>
          <% supervisors = Map.get(@supervisors_map, @detail_service_id, []) %>
          <div class="mt-4 p-3 bg-base-200 rounded-lg">
            <div class="flex items-center justify-between mb-2">
              <div>
                <p class="text-sm font-medium">{gettext("Supervisors")}</p>
                <p class="text-xs text-base-content/60">
                  {gettext("They see their assigned services at")} <code>/services/supervised</code>
                  {gettext(
                    "(read-only): a per-service summary and full per-service stats. Removing a supervisor"
                  )}
                  {gettext("revokes the access immediately.")}
                </p>
              </div>
              <button
                phx-click="toggle_supervisor_form"
                phx-value-service-id={@detail_service_id}
                class="btn btn-ghost btn-xs"
              >
                {if @supervisor_search_service_id == @detail_service_id,
                  do: gettext("Close"),
                  else: gettext("Add supervisor")}
              </button>
            </div>

            <div :if={supervisors == []} class="text-xs text-base-content/40">
              {gettext("No supervisors assigned.")}
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
                  title={gettext("Remove supervisor")}
                  aria-label={gettext("Remove supervisor")}
                >
                  ×
                </button>
              </span>
            </div>

            <div :if={@supervisor_search_service_id == @detail_service_id} class="mt-3">
              <%!-- `phx-keyup` es el mecanismo de este buscador (el handler
                   recibe %{"value" => q}); el `phx-change` que estaba aquí
                   sobraba y reventaba en el cliente en cada tecla (un
                   phx-change exige un <form> alrededor). --%>
              <.input
                type="text"
                name="supervisor_query"
                value={@supervisor_search_query}
                placeholder={gettext("Search by email or name…")}
                phx-keyup="search_supervisor_users"
                id="supervisor-search"
              />
              <div
                :if={@supervisor_search_query != "" and @supervisor_search_results == []}
                class="text-xs text-base-content/40 mt-2"
              >
                {gettext("No matches.")}
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
              {gettext("Close")}
            </button>
          </div>
        </.modal>

        <%!-- Delete confirmation modal --%>
        <.admin_delete_modal
          :if={@delete_target_id}
          id="delete-service-modal"
          on_close="cancel_delete"
          title={gettext("Delete service")}
          target_label={@delete_target_name}
          target_span_id="delete-service-name"
          confirm_event="delete_service"
          confirm_value={@delete_target_id}
          confirm_button_id="confirm-delete-service"
          cancel_button_id="cancel-delete-service"
          warning_intro={gettext("Will be permanently erased:")}
          warning_items={[
            gettext("The service API key"),
            gettext("The models granted to the service"),
            gettext("The assigned supervisors")
          ]}
        />

        <%!-- Services table --%>
        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>
                  <.sort_button
                    event="sort_services"
                    field={:name}
                    label={gettext("Service")}
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <%!-- Orden: identidad → campos QUE COMPARTE con Usuarios (mismo
                     orden en ambas tablas) → resto de campos propios → Creado →
                     acciones. --%>
                <th>{gettext("Keys")}</th>
                <th class="text-right">
                  <.sort_button
                    event="sort_services"
                    field={:limit}
                    label={gettext("Monthly cap (UTC month)")}
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th class="text-right">
                  <.sort_button
                    event="sort_services"
                    field={:monthly_spend}
                    label={gettext("Monthly spend")}
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th class="text-right">
                  <.sort_button
                    event="sort_services"
                    field={:total_spend}
                    label={gettext("Total spend")}
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th>{gettext("Models")}</th>
                <th class="text-right">
                  <.sort_button
                    event="sort_services"
                    field={:requests}
                    label="Requests 30d"
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th>
                  <.sort_button
                    event="sort_services"
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
                  monthly_spend={@monthly_spend_by_service}
                  total_spend={@total_spend_by_service}
                  service_credit={@service_credit}
                  supervisors_map={@supervisors_map}
                  keys_by_service={@keys_by_service}
                  timezone={@timezone}
                />
              </tr>
            </tbody>
          </table>
          <.empty_state
            :if={@services_empty?}
            id="services-empty"
            icon="hero-wrench-screwdriver"
            title={gettext("No services yet.")}
          />
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Components ---------------------------------------------------------------

  attr :service, :map, required: true
  attr :granted_models, :map, required: true
  attr :stats, :map, required: true
  attr :monthly_spend, :map, required: true
  attr :total_spend, :map, required: true
  attr :service_credit, :map, required: true
  attr :supervisors_map, :map, required: true
  attr :keys_by_service, :map, required: true
  attr :timezone, :string, required: true

  defp service_row(assigns) do
    ~H"""
    <td>
      <.admin_identity
        icon="hero-wrench-screwdriver"
        title={@service.name}
        subtitle={"#{@service.concurrency_limit || 5} conc. · #{@service.rpm_limit || 60} RPM"}
        truncate
      />
    </td>
    <td>
      <.keys_badge
        subject_id={@service.id}
        count={length(Map.get(@keys_by_service, @service.id, []))}
        open_event="manage_keys"
      />
    </td>
    <td class="min-w-[150px]" id={"credit-#{@service.id}"}>
      <.budget_cell credit={Map.get(@service_credit, @service.id)} />
    </td>
    <td class="text-right text-xs font-mono" id={"monthly-spend-#{@service.id}"}>
      ${format_usd(Map.get(@monthly_spend, @service.id, Decimal.new(0)))}
    </td>
    <td class="text-right text-xs font-mono" id={"total-spend-#{@service.id}"}>
      ${format_usd(Map.get(@total_spend, @service.id, Decimal.new(0)))}
    </td>
    <td>
      <button
        phx-click="edit_models"
        phx-value-id={@service.id}
        class="badge badge-sm badge-outline gap-1 hover:badge-primary transition-colors cursor-pointer"
        id={"edit-models-#{@service.id}"}
        title={gettext("Manage the service models")}
      >
        <.icon name="hero-rectangle-stack" class="w-3 h-3" />
        {length(Map.get(@granted_models, @service.id, []))} modelos
      </button>
    </td>
    <td class="text-right text-xs font-mono">
      {format_number(stat_for(@stats, @service.id, :total_requests))}
    </td>
    <td class="text-xs text-base-content/50">
      {format_date(@service.inserted_at, @timezone)}
    </td>
    <td>
      <div class="flex gap-1">
        <.link
          navigate={~p"/stats/services/#{@service.id}"}
          class="btn btn-xs btn-ghost"
          id={"stats-#{@service.id}"}
          title={gettext("View this service's consolidated stats")}
          aria-label={gettext("View the service's stats")}
        >
          <.icon name="hero-chart-bar" class="w-3 h-3" />
        </.link>
        <button
          phx-click="edit_service"
          phx-value-id={@service.id}
          class="btn btn-xs btn-ghost"
          id={"edit-#{@service.id}"}
          title={gettext("Edit service")}
          aria-label={gettext("Edit service")}
        >
          <.icon name="hero-pencil" class="w-3 h-3" />
        </button>
        <button
          phx-click="view_detail"
          phx-value-id={@service.id}
          class="btn btn-xs btn-ghost"
          id={"detail-#{@service.id}"}
          title={gettext("View detail: stats and supervisors")}
          aria-label={gettext("View the service detail")}
        >
          <.icon name="hero-eye" class="w-3 h-3" />
        </button>
        <button
          phx-click="open_delete_modal"
          phx-value-id={@service.id}
          phx-value-name={@service.name}
          class="btn btn-xs btn-ghost text-error"
          id={"delete-#{@service.id}"}
          title={gettext("Delete service")}
          aria-label={gettext("Delete service")}
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
end
