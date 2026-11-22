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

  # Page size for the table: the slice asked from Postgres and the ONLY set the
  # per-row aggregates (stats/credit/supervisors/keys) are computed for. Same
  # size as the Users table. Before this, the listing pulled up to 500 rows and
  # aggregated over every one of them on each load.
  @per_page 30

  # Per-service credit TTL: a warm page (search keystroke, sort, page change) is
  # pure hits; a cold one pays a single batched load.
  @credit_ttl_ms 5_000

  # The subset of `Service.changeset/2`'s `@permitted` fields worth recording
  # in `service.update`; auditing anything else logs keys the row never stores.
  @service_audit_fields ~w(name concurrency_limit rpm_limit monthly_spend_limit_usd unlimited_spend)

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
        |> assign(:editing_key_id, nil)
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
        |> assign(:page, 1)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, 0)
        |> assign(:total_pages, 1)
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

  # Loads ONE page of services (and the per-row data ONLY for that page) and
  # re-streams it. Search, count, ordering and the page slice are resolved in
  # Postgres: before, the whole table (up to 500 rows) came into the BEAM and
  # stats/credit/supervisors/keys were computed for every service, not just the
  # ones on screen.
  defp load_services(socket) do
    page =
      Accounts.list_services_page(
        search: socket.assigns[:search_query] || "",
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        sort_field: socket.assigns.sort_field,
        sort_direction: socket.assigns.sort_direction
      )

    services = page.entries
    service_ids = Enum.map(services, & &1.id)

    granted_models =
      from(sma in ServiceModel,
        where: sma.service_id in ^service_ids,
        select: {sma.service_id, sma.model_id}
      )
      |> Repo.all()
      |> Enum.group_by(fn {service_id, _} -> service_id end, fn {_, model_id} -> model_id end)

    timezone = socket.assigns[:timezone] || "Etc/UTC"

    # The 30d aggregate is the only heavy query of the listing without a cache
    # of its own: without this it re-ran on every keystroke, sort and page
    # change. Keyed by the page's ids (sorted) + timezone, 5s TTL — the same
    # contract as the spend/credit maps below.
    stats =
      DashboardCache.fetch_or_compute(
        {:services_stats_30d, Enum.sort(service_ids), timezone},
        fn -> service_stats(service_ids, timezone) end,
        ttl: @credit_ttl_ms
      )

    # Gasto mensual / total por servicio — mismas columnas que la tabla de
    # Usuarios. Agregados whole-table cacheados (5s TTL) para no re-escanear
    # request_logs en cada keystroke de búsqueda/orden.
    monthly_spend =
      DashboardCache.fetch_or_compute({:services_monthly_spend, timezone}, fn ->
        Budgets.spend_by_service()
      end)

    # Lifetime total: it walks every retained partition (Merge Append over ~90
    # of them), so it gets the 60s TTL its Users twin already uses — lifetime
    # spend barely moves in 5 seconds and this is the page's most expensive
    # scan.
    total_spend =
      DashboardCache.fetch_or_compute(
        {:services_total_spend},
        fn -> Logs.total_spend_by_service() end,
        ttl: 60_000
      )

    socket
    |> assign(:all_services, services)
    |> assign(:granted_models, granted_models)
    |> assign(:service_stats, stats)
    |> assign(:monthly_spend_by_service, monthly_spend)
    |> assign(:service_credit, service_credit(services))
    |> assign(:total_spend_by_service, total_spend)
    |> assign(:supervisors_map, build_supervisors_map(service_ids))
    |> assign(:keys_by_service, Accounts.count_active_api_keys_by_service(service_ids))
    |> assign(:page, page.page)
    |> assign(:total_count, page.total)
    |> assign(:total_pages, page.total_pages)
    |> stream_services()
  end

  # Each service's cap + debited consumption (the same consumed/cap pair the
  # Users column renders), computed ONLY for the services on the page.
  #
  # One cache entry per service (5s TTL) instead of one whole-table entry: a
  # warm page is pure hits, a cold page pays a single batched
  # `Credits.service_summaries/1`. The entry's key embeds the row's own cap, so
  # editing the cap is never served stale from the cache.
  defp service_credit([]), do: %{}

  defp service_credit(services) do
    {hits, missed} =
      Enum.reduce(services, {%{}, []}, fn service, {hits, missed} ->
        case DashboardCache.fetch(service_credit_key(service)) do
          {:ok, credit} -> {Map.put(hits, service.id, credit), missed}
          :miss -> {hits, [service | missed]}
        end
      end)

    case missed do
      [] ->
        hits

      missed ->
        missed = Enum.reverse(missed)
        computed = Credits.service_summaries(missed)
        keys = Map.new(missed, fn service -> {service.id, service_credit_key(service)} end)

        Enum.each(computed, fn {service_id, credit} ->
          DashboardCache.put(Map.fetch!(keys, service_id), credit, @credit_ttl_ms)
        end)

        Map.merge(hits, computed)
    end
  end

  defp service_credit_key(service) do
    {:service_credit, service.id, service.monthly_spend_limit_usd, service.unlimited_spend}
  end

  # Per-service 30d aggregate. Stays RAW on purpose: `request_metrics_hourly`
  # has no `service_id` dimension (only user/member/model/provider), so the
  # rollup cannot answer it — the covering index on
  # `request_logs (service_id, inserted_at)` is what makes this cheap.
  # `avg_latency_ms` is gone: no surface renders it, and the repo rule is to
  # select only the columns that are used.
  defp service_stats([], _timezone), do: %{}

  defp service_stats(service_ids, timezone) do
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
        total_output_tokens: sum(l.completion_tokens)
      }
    )
    |> Repo.all(timeout: 120_000)
    |> Map.new(fn s -> {s.service_id, s} end)
  end

  # Re-streams the page `load_services/1` already fetched. Pure assign work:
  # zero queries — the search and the page slice were resolved in Postgres, so
  # the only ordering left here is the one SQL cannot express.
  #
  # LIMITATION: `limit` (rendered text), `requests`, `monthly_spend` and
  # `total_spend` (aggregates computed outside Postgres) are sorted WITHIN the
  # current page only — the page slice itself comes from the DB in name order.
  # Making those global again would need the aggregate as a SQL join, which is
  # a much larger change than this table justifies (the Users table carries the
  # same documented limitation). `name` and `inserted_at` are ordered in SQL, so
  # those two are global across pages.
  defp stream_services(socket) do
    services = socket.assigns.all_services

    sorted =
      if socket.assigns.sort_field in Accounts.service_page_sql_sorts() do
        services
      else
        sort_services(services, socket.assigns.sort_field, socket.assigns.sort_direction, socket)
      end

    socket
    |> stream(:services, sorted, reset: true)
    |> assign(:services_empty?, socket.assigns.total_count == 0)
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
     |> assign(:page, 1)
     |> load_services()}
  end

  ## Events — paginado ------------------------------------------------------

  # Read-only navigation: the DB clamps an out-of-range page and reports the
  # effective one back (mirror of the Users table).
  def handle_event("go_to_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:page, parse_page(page))
     |> load_services()}
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
       |> assign(:page, 1)
       |> load_services()}
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
    with {:ok, service_id} <- cast_id(service_id),
         %Service{} = service <- Accounts.get_service(service_id) do
      changeset = Accounts.change_service(service)

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :service))
       |> assign(:editing_service_id, service.id)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Service not found."))}
    end
  end

  def handle_event("edit_service", _params, socket), do: {:noreply, socket}

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
    with {:ok, service_id} <- cast_id(service_id),
         %Service{} = service <- Accounts.get_service(service_id) do
      delete_service_row(socket, service)
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Service not found."))}
    end
  end

  def handle_event("delete_service", _params, socket), do: {:noreply, socket}

  ## Events — detail / models modals ---------------------------------------

  def handle_event("view_detail", %{"id" => service_id}, socket) do
    with {:ok, service_id} <- cast_id(service_id) do
      {:noreply, assign(socket, :detail_service_id, service_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("view_detail", _params, socket), do: {:noreply, socket}

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :detail_service_id, nil)}
  end

  def handle_event("edit_models", %{"id" => service_id}, socket) do
    with {:ok, service_id} <- cast_id(service_id) do
      # The model catalog is loaded HERE, not in `load_services/1`: the listing
      # only needs it when this modal opens, and it used to be a whole-table
      # read on every keystroke, sort and page change.
      models =
        from(ma in Model, order_by: [asc: ma.name])
        |> Repo.all()

      {:noreply, socket |> assign(:models, models) |> assign(:models_service_id, service_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("edit_models", _params, socket), do: {:noreply, socket}

  def handle_event("close_models", _params, socket) do
    {:noreply, assign(socket, :models_service_id, nil)}
  end

  ## Events — API keys (N keys con etiqueta, igual que un usuario) ---------

  # Las claves de un servicio se cargan solo al abrir su panel: el listado no
  # paga N+1 por cada fila.
  def handle_event("manage_keys", %{"id" => service_id}, socket) do
    with {:ok, service_id} <- cast_id(service_id),
         %Service{} = service <- Accounts.get_service(service_id) do
      {:noreply,
       socket
       |> assign(:keys_service_id, service.id)
       |> assign(:keys_service_name, service.name)
       |> assign(:new_token, nil)
       |> load_service_keys(service.id)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Service not found."))}
    end
  end

  def handle_event("manage_keys", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_manage_keys", _params, socket) do
    {:noreply,
     socket
     |> assign(:keys_service_id, nil)
     |> assign(:keys_service_name, nil)
     |> assign(:keys, [])
     |> assign(:keys_spend, %{})
     |> assign(:new_token, nil)
     |> assign(:editing_key_id, nil)}
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

  # Submit del form inline: cambia el label de la key del servicio en edición.
  # Va ANTES del clause del lápiz — su pattern es un superconjunto (el payload
  # del submit también trae "key-id") y el orden de clauses decide.
  #
  # `Accounts.rename_api_key/3` is the single rename path for users and
  # services: it re-reads the row, enforces `service_id` ownership and writes
  # the `api_key.rename` audit entry with old/new label. The surface only
  # keeps the session-side guard (panel closed ⇒ nobody renames anything).
  def handle_event(
        "rename_service_key",
        %{"key-id" => key_id, "key" => %{"label" => label}},
        socket
      )
      when is_binary(label) do
    service_id = socket.assigns.keys_service_id

    with true <- is_binary(service_id),
         {:ok, key_id} <- cast_id(key_id),
         %{} = api_key <- Accounts.get_service_api_key(key_id),
         # Chequeo hermético: keys_service_id nil (panel cerrado) + una key de
         # usuario (service_id nil) era true por nil == nil.
         true <- api_key.service_id == service_id,
         {:ok, _renamed} <-
           Accounts.rename_api_key(api_key, label,
             service_id: service_id,
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Key renamed."))
       |> assign(:editing_key_id, nil)
       |> load_service_keys(service_id)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not rename the key."))}
    end
  end

  # Lápiz de la fila: abre el form inline de rename.
  def handle_event("rename_service_key", %{"key-id" => key_id}, socket)
      when is_binary(key_id) do
    {:noreply, assign(socket, :editing_key_id, key_id)}
  end

  def handle_event("rename_service_key", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_rename_key", _params, socket) do
    {:noreply, assign(socket, :editing_key_id, nil)}
  end

  # Revoke = issue a new key and invalidate the previous one (W2 lifecycle): the
  # old row stays `revoked` (its hash is what keeps the historical attribution)
  # and the replacement token is shown once in `new_token`.
  def handle_event("revoke_service_key", %{"key-id" => api_key_id}, socket) do
    service_id = socket.assigns.keys_service_id

    with true <- is_binary(service_id),
         {:ok, api_key_id} <- cast_id(api_key_id),
         %{} = api_key <- Accounts.get_service_api_key(api_key_id),
         # Mismo chequeo hermético que el rename: nil == nil dejaba pasar una
         # key de usuario con el panel cerrado.
         true <- api_key.service_id == service_id,
         {:ok, replacement, token} <- Accounts.revoke_and_replace_api_key(api_key) do
      audit(socket, "api_key.revoke", "api_key", api_key.id, %{
        "label" => api_key.label,
        "service_id" => api_key.service_id,
        "replacement_id" => replacement.id
      })

      {:noreply,
       socket
       |> assign(:new_token, token)
       |> assign(:editing_key_id, nil)
       |> put_flash(:info, gettext("Key revoked."))
       |> load_service_keys(service_id)
       |> load_services()}
    else
      {:error, :not_active} ->
        {:noreply, put_flash(socket, :error, gettext("That key is no longer active."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Could not revoke the key."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Key not found."))}
    end
  end

  # Delete = soft-hide (W2): the row disappears from every listing and its token
  # stops authenticating; `request_logs` keeps the attribution because that
  # table has no FK to `api_keys`.
  def handle_event("hide_service_key", %{"key-id" => api_key_id}, socket) do
    service_id = socket.assigns.keys_service_id

    with true <- is_binary(service_id),
         {:ok, api_key_id} <- cast_id(api_key_id),
         %{} = api_key <- Accounts.get_service_api_key(api_key_id),
         true <- api_key.service_id == service_id,
         {:ok, _hidden} <- Accounts.hide_api_key(api_key) do
      audit(socket, "api_key.hide", "api_key", api_key.id, %{
        "label" => api_key.label,
        "service_id" => api_key.service_id
      })

      {:noreply,
       socket
       |> put_flash(:info, gettext("Key deleted. Its historical consumption is preserved."))
       |> assign(:editing_key_id, nil)
       |> load_service_keys(service_id)
       |> load_services()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Key not found."))}
    end
  end

  def handle_event("hide_service_key", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_new_key_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  # Limpia las sticky routes del SERVICIO (todas sus keys): su próxima petición
  # re-evalúa proveedores en vez de quedarse pegado a uno degradado.
  def handle_event("clear_service_sticky_routes", %{"id" => service_id}, socket) do
    with {:ok, service_id} <- cast_id(service_id),
         %Service{} = service <- Accounts.get_service(service_id) do
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
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Service not found."))}
    end
  end

  def handle_event("clear_service_sticky_routes", _params, socket), do: {:noreply, socket}

  ## Events — model grants ------------------------------------------------

  def handle_event("toggle_model", %{"target-id" => service_id, "model-id" => model_id}, socket) do
    with {:ok, service_id} <- cast_id(service_id),
         {:ok, model_id} <- cast_id(model_id) do
      toggle_service_model(socket, service_id, model_id)
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
    end
  end

  def handle_event("toggle_model", _params, socket), do: {:noreply, socket}

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
    # Both ids come from the client: cast + existence check BEFORE the insert,
    # so a forged/non-UUID payload is a flash and never a CastError or a
    # ForeignKeyViolation (W6 adds the FK constraint on `service_supervisors`,
    # and its changeset error lands in the same `{:error, changeset}` branch).
    with {:ok, service_id} <- cast_id(service_id),
         {:ok, user_id} <- cast_id(user_id),
         %Service{} <- Accounts.get_service(service_id),
         %{} <- Accounts.get_user(user_id),
         {:ok, _supervisor} <- Accounts.add_service_supervisor(service_id, user_id) do
      audit(socket, "service_supervisor.add", "service", service_id, %{"user_id" => user_id})

      {:noreply,
       socket
       |> put_flash(:info, gettext("Supervisor added."))
       |> assign(:supervisor_search_results, [])
       |> assign(:supervisor_search_query, "")
       |> load_services()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not add the supervisor."))}
    end
  end

  def handle_event("add_supervisor", _params, socket), do: {:noreply, socket}

  def handle_event(
        "remove_supervisor",
        %{"service-id" => service_id, "user-id" => user_id},
        socket
      ) do
    with {:ok, service_id} <- cast_id(service_id),
         {:ok, user_id} <- cast_id(user_id),
         {:ok, _} <- Accounts.remove_service_supervisor(service_id, user_id) do
      audit(socket, "service_supervisor.remove", "service", service_id, %{"user_id" => user_id})

      {:noreply,
       socket
       |> put_flash(:info, gettext("Supervisor removed."))
       |> load_services()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the supervisor."))}
    end
  end

  def handle_event("remove_supervisor", _params, socket), do: {:noreply, socket}

  defp service_supervisor_user_ids(socket, service_id) do
    case Map.get(socket.assigns.supervisors_map, service_id, []) do
      list when is_list(list) -> Enum.map(list, & &1.user_id)
      _ -> []
    end
  end

  ## Private helpers — save ----------------------------------------------

  # Client-supplied ids arrive as strings: cast before ANY DB call so a
  # malformed id becomes a flash / empty state instead of an
  # `Ecto.Query.CastError` that takes the whole LiveView down.
  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_id), do: :error

  defp delete_service_row(socket, service) do
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

  defp toggle_service_model(socket, service_id, model_id) do
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
         |> put_flash(:info, gettext("Models updated."))
         |> assign(:granted_models, granted_models)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
    end
  end

  # Keys activas del servicio + consumo por key, cargadas solo al abrir el panel.
  # Revoked keys are soft-deleted: only active keys render (attribution survives
  # in the DB, but revoked rows are never listed in the panel).
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

  # L38 — doble submit o submit encolado detrás de Cancelar: el id de edición
  # ya es nil. No-op en vez de FunctionClauseError.
  defp save_service(socket, nil, _service_params), do: {:noreply, socket}

  defp save_service(socket, service_id, service_params) when is_binary(service_id) do
    with {:ok, service_id} <- cast_id(service_id),
         %Service{} = service <- Accounts.get_service(service_id) do
      case Accounts.update_service(service, service_params) do
        {:ok, updated} ->
          # Only fields the changeset actually accepts may be audited: a
          # `Map.take` over params that `@permitted` never casts logs keys the
          # service does not have (`status`, `default_*_limit`) and hides the
          # ones it does.
          audit(socket, "service.update", "service", updated.id, %{
            "name" => updated.name,
            "changes" => Map.take(service_params, @service_audit_fields)
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
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Service not found."))}
    end
  end

  ## Template helpers -----------------------------------------------------

  defp to_sort_field(field) when is_binary(field) do
    {:ok, String.to_existing_atom(field)}
  rescue
    ArgumentError -> :error
  end

  # `go_to_page` carries the page as a string from the client: garbage is page 1
  # (the DB clamps the upper bound and reports the effective page back).
  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {i, ""} when i > 0 -> i
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

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

  # Sub label for display: the name, or the unlimited marker when the service has no cap
  defp limit_label(%{unlimited_spend: true}), do: gettext("Unlimited")

  defp limit_label(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: gettext("$%{amount}/month", amount: Decimal.to_string(limit))

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
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New service")}
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
                label={gettext("Unlimited")}
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
            hide_event="hide_service_key"
            dismiss_event="dismiss_new_key_token"
            sticky_event="clear_service_sticky_routes"
            rename_event="rename_service_key"
            cancel_rename_event="cancel_rename_key"
            editing_key_id={@editing_key_id}
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
            · {gettext("Cap:")} {limit_label(detail_service(assigns))}
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
            gettext("Its API keys (all active and revoked)"),
            gettext("The models granted to the service"),
            gettext("The assigned supervisors"),
            gettext("Its credit top-ups"),
            gettext("All its request history (request_logs): the FK is ON DELETE CASCADE")
          ]}
        />

        <%!-- Services table: identidad → campos QUE COMPARTE con Usuarios
             (mismo orden en ambas tablas) → resto de campos propios → Creado
             → acciones. --%>
        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="services"
            rows={@streams.services}
            row_item={fn {_id, service} -> service end}
            row_class="align-top"
            sort_field={@sort_field}
            sort_direction={@sort_direction}
            sort_event="sort_services"
            empty?={@services_empty?}
          >
            <:col :let={service} label={gettext("Service")} field={:name}>
              <.admin_identity
                icon="hero-wrench-screwdriver"
                title={service.name}
                subtitle={"#{service.concurrency_limit || 5} conc. · #{service.rpm_limit || 60} RPM"}
                truncate
              />
            </:col>
            <:col :let={service} label={gettext("Keys")}>
              <.keys_badge
                subject_id={service.id}
                count={Map.get(@keys_by_service, service.id, 0)}
                open_event="manage_keys"
              />
            </:col>
            <:col
              :let={service}
              label={gettext("Monthly cap (UTC month)")}
              field={:limit}
              align="right"
              tooltip={
                gettext(
                  "Credit consumed against the service's monthly cap — the same reading as the Users list."
                )
              }
            >
              <div class="min-w-[150px]" id={"credit-#{service.id}"}>
                <.budget_cell credit={Map.get(@service_credit, service.id)} />
              </div>
            </:col>
            <:col :let={service} label={gettext("Monthly spend")} field={:monthly_spend} align="right">
              <span class="text-xs font-mono" id={"monthly-spend-#{service.id}"}>
                ${format_usd(Map.get(@monthly_spend_by_service, service.id, Decimal.new(0)))}
              </span>
            </:col>
            <:col :let={service} label={gettext("Total spend")} field={:total_spend} align="right">
              <span class="text-xs font-mono" id={"total-spend-#{service.id}"}>
                ${format_usd(Map.get(@total_spend_by_service, service.id, Decimal.new(0)))}
              </span>
            </:col>
            <:col :let={service} label={gettext("Models")}>
              <button
                phx-click="edit_models"
                phx-value-id={service.id}
                class="badge badge-sm badge-outline gap-1 hover:badge-primary transition-colors cursor-pointer"
                id={"edit-models-#{service.id}"}
                title={gettext("Manage the service models")}
              >
                <.icon name="hero-rectangle-stack" class="w-3 h-3" />
                {gettext("%{count} models", count: length(Map.get(@granted_models, service.id, [])))}
              </button>
            </:col>
            <:col :let={service} label={gettext("Requests 30d")} field={:requests} align="right">
              <span class="text-xs font-mono">
                {format_number(stat_for(@service_stats, service.id, :total_requests))}
              </span>
            </:col>
            <:col :let={service} label={gettext("Created")} field={:inserted_at}>
              <span class="text-xs text-base-content/50">
                {format_date(service.inserted_at, @timezone)}
              </span>
            </:col>
            <:action :let={service}>
              <.link
                navigate={~p"/stats/services/#{service.id}"}
                class="btn btn-xs btn-ghost"
                id={"stats-#{service.id}"}
                title={gettext("View this service's consolidated stats")}
                aria-label={gettext("View the service's stats")}
              >
                <.icon name="hero-chart-bar" class="w-3 h-3" />
              </.link>
              <button
                phx-click="edit_service"
                phx-value-id={service.id}
                class="btn btn-xs btn-ghost"
                id={"edit-#{service.id}"}
                title={gettext("Edit service")}
                aria-label={gettext("Edit service")}
              >
                <.icon name="hero-pencil" class="w-3 h-3" />
              </button>
              <button
                phx-click="view_detail"
                phx-value-id={service.id}
                class="btn btn-xs btn-ghost"
                id={"detail-#{service.id}"}
                title={gettext("View detail: stats and supervisors")}
                aria-label={gettext("View the service detail")}
              >
                <.icon name="hero-eye" class="w-3 h-3" />
              </button>
              <button
                phx-click="open_delete_modal"
                phx-value-id={service.id}
                phx-value-name={service.name}
                class="btn btn-xs btn-ghost text-error"
                id={"delete-#{service.id}"}
                title={gettext("Delete service")}
                aria-label={gettext("Delete service")}
              >
                <.icon name="hero-trash" class="w-3 h-3" />
              </button>
            </:action>
            <:empty>
              <.icon name="hero-wrench-screwdriver" class="size-10 mx-auto mb-2 opacity-40" />
              <p class="text-sm font-medium text-base-content/60">{gettext("No services yet.")}</p>
            </:empty>
          </.table>
          <.admin_pagination
            id="services-pagination"
            page={@page}
            per_page={@per_page}
            total={@total_count}
            total_pages={@total_pages}
          />
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Components ---------------------------------------------------------------

  defp stat_for(stats, service_id, key) do
    case Map.get(stats, service_id) do
      nil -> 0
      stat -> Map.get(stat, key) || 0
    end
  end
end
