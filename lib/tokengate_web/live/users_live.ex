defmodule TokengateWeb.UsersLive do
  @moduledoc """
  Admin-only CRUD for users.

  Admins can:
    * List all users
    * Create users (email + name + password + global_role)
    * Edit users (name, global_role, status)
    * Reset passwords
    * Suspend/activate users

  The root admin (created via seeds/env vars) cannot be suspended or
  deleted by other admins — it's the bootstrap account.
  """

  use TokengateWeb, :live_view

  import TokengateWeb.AdminComponents
  import TokengateWeb.KeysPanel
  import TokengateWeb.StatsHelpers, only: [budget_cell: 1, format_usd: 1]

  alias Tokengate.Accounts
  alias Tokengate.Accounts.User
  alias Tokengate.Credits
  alias Tokengate.Metrics.DashboardCache

  # Paginado de la tabla: el listado completo se ordena en memoria (el orden
  # depende de agregados de consumo), así que la página solo recorta el tramo
  # que va al stream.
  @per_page_options [25, 50, 100]
  @default_per_page 25

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Usuarios · Tokengate")
      |> stream_configure(:users, dom_id: &"user-#{&1.id}")
      |> assign(:form, nil)
      |> assign(:editing_user_id, nil)
      |> assign(:reset_user_id, nil)
      |> assign(:form_mode, nil)
      |> assign(:delete_target_id, nil)
      |> assign(:delete_target_email, nil)
      |> assign(:all_groups, Accounts.list_groups())
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:search_query, "")
      |> assign(:sort_field, :name)
      |> assign(:sort_direction, :asc)
      |> assign(:filter_today_spend, false)
      |> assign(:editing_groups_user_id, nil)
      |> assign(:editing_groups_user_name, nil)
      |> assign(:editing_group_ids, [])
      |> assign(:editing_user_sub_id, nil)
      |> assign(:keys_user_id, nil)
      |> assign(:keys_user_name, nil)
      |> assign(:keys, [])
      |> assign(:keys_spend, %{})
      |> assign(:keys_counts, %{})
      |> assign(:new_key_token, nil)
      |> assign(:page, 1)
      |> assign(:per_page, @default_per_page)
      |> assign(:per_page_options, @per_page_options)
      |> assign(:total_count, 0)
      |> assign(:total_pages, 1)
      |> require_admin_hook()
      |> load_users()

    {:ok, socket}
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

  # Sortable columns and their value extractors. Each function receives a
  # user plus the lookup assigns (spend maps, group map) and returns a
  # comparable value.
  @sort_columns ~w(name role status groups credit monthly_spend total_spend inserted_at)a

  defp load_users(socket) do
    search = socket.assigns[:search_query] || ""
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    users = Accounts.list_users()

    filtered =
      if search == "" do
        users
      else
        search_lower = String.downcase(search)

        Enum.filter(users, fn u ->
          String.contains?(String.downcase(u.name || ""), search_lower) or
            String.contains?(String.downcase(u.email), search_lower)
        end)
      end

    # Both spend maps are whole-table aggregates over request_logs (the
    # lifetime one joins every partition) and `load_users/1` re-runs on
    # every search keystroke, sort click and filter toggle. Cache them in
    # DashboardCache (5s TTL) so interactive events reuse one shared entry
    # per timezone instead of re-scanning the log table per event — same
    # pattern as DashboardLive.
    spend_by_user =
      DashboardCache.fetch_or_compute({:users_spend_by_user, timezone}, fn ->
        Tokengate.Budgets.spend_by_user(timezone)
      end)

    total_spend_by_user =
      DashboardCache.fetch_or_compute({:users_total_spend_by_user}, fn ->
        Tokengate.Logs.total_spend_by_user()
      end)

    user_groups = load_user_groups(filtered)

    # Conteo de claves activas por usuario — misma columna «Claves» que la
    # tabla de servicios, en una sola query (nada de N+1 por fila).
    keys_counts = Accounts.count_active_api_keys_by_user(Enum.map(filtered, & &1.id))

    # Límite de gasto efectivo por usuario (propio o heredado del perfil de límites) más el
    # gasto del mes. En lote: una query por sujeto, nunca una por membresía.
    users_credit =
      DashboardCache.fetch_or_compute(
        {:users_credit_by_user, Enum.map(filtered, & &1.id)},
        fn -> load_users_credit(filtered) end
      )

    # Filter by today's spend when toggle is active
    filtered =
      if socket.assigns.filter_today_spend do
        Enum.filter(filtered, fn u ->
          case Map.get(spend_by_user, u.id) do
            %{daily_usd: d} -> Decimal.compare(d, Decimal.new(0)) == :gt
            _ -> false
          end
        end)
      else
        filtered
      end

    sort_ctx = %{
      spend_by_user: spend_by_user,
      total_spend_by_user: total_spend_by_user,
      user_groups: user_groups,
      users_credit: users_credit
    }

    sorted =
      sort_users(filtered, socket.assigns.sort_field, socket.assigns.sort_direction, sort_ctx)

    total_count = length(sorted)
    total_pages = max(1, div(total_count + socket.assigns.per_page - 1, socket.assigns.per_page))

    # La página pedida se recorta al rango vigente: al filtrar, ordenar o
    # borrar usuarios la última página puede quedarse sin filas.
    page = socket.assigns.page |> max(1) |> min(total_pages)
    page_rows = Enum.slice(sorted, (page - 1) * socket.assigns.per_page, socket.assigns.per_page)

    socket
    |> assign(:spend_by_user, spend_by_user)
    |> assign(:total_spend_by_user, total_spend_by_user)
    |> assign(:user_groups, user_groups)
    |> assign(:keys_counts, keys_counts)
    |> assign(:users_credit, users_credit)
    |> assign(:users_empty?, sorted == [])
    |> assign(:page, page)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> stream(:users, page_rows, reset: true)
  end

  defp load_user_groups(users) do
    users
    |> Enum.map(& &1.id)
    |> Accounts.list_groups_by_user_ids()
  end

  ## Sorting ---------------------------------------------------------------

  # Applies the selected column sort. Admins keep floating to the top within
  # each group (as before); the column comparator breaks the rest.
  defp sort_users(users, field, direction, ctx) do
    Enum.sort_by(
      users,
      fn u -> {if(u.global_role == "admin", do: 0, else: 1), sort_value(u, field, ctx)} end,
      fn {role_a, val_a}, {role_b, val_b} ->
        cond do
          role_a != role_b -> role_a < role_b
          true -> compare_sort_values(val_a, val_b, direction)
        end
      end
    )
  end

  defp sort_value(user, :name, _ctx), do: String.downcase(user.name || user.email)
  defp sort_value(user, :role, _ctx), do: user.global_role || ""
  defp sort_value(user, :status, _ctx), do: user.status || ""

  # Consumo del límite mensual efectivo (nil = sin límite definido): la misma
  # cifra que muestra la celda, para que el orden coincida con lo que se lee.
  defp sort_value(user, :credit, ctx) do
    case Map.get(ctx.users_credit, user.id) do
      %{limit_usd: limit, limit_spend_usd: %Decimal{} = spent} when not is_nil(limit) ->
        Decimal.to_float(spent)

      _ ->
        nil
    end
  end

  defp sort_value(user, :groups, ctx) do
    case Map.get(ctx.user_groups, user.id, []) do
      [] -> ""
      groups -> groups |> Enum.map(&String.downcase(&1.name)) |> Enum.join(", ")
    end
  end

  defp sort_value(user, :monthly_spend, ctx) do
    case Map.get(ctx.spend_by_user, user.id) do
      nil -> nil
      spend -> spend.real_monthly_usd
    end
  end

  defp sort_value(user, :total_spend, ctx) do
    Map.get(ctx.total_spend_by_user, user.id)
  end

  defp sort_value(user, :inserted_at, _ctx), do: user.inserted_at

  # Presupuesto + top-ups por usuario, en lote (una query por tipo de sujeto).
  # El usuario hereda el techo del presupuesto mensual al que pertenece si no
  # define el suyo; sin presupuesto mensual el sujeto es él mismo y su único
  # camino de gasto son sus top-ups.
  defp load_users_credit(users) do
    memberships = Tokengate.Accounts.list_users_with_memberships(Enum.map(users, & &1.id))

    summaries =
      memberships
      |> Enum.flat_map(fn {_user_id, ms} -> ms end)
      |> Credits.summaries()

    # Sin membresía no hay resumen del motor: el sujeto es el propio usuario y
    # hay que leer su gasto y sus top-ups igual que en el resto de superficies
    # (en lote, no por usuario). Sin esto la columna diría «sin presupuesto» a
    # quien sí tiene crédito, y ceros a quien tiene techo propio con gasto.
    own_subjects =
      for user <- users,
          Map.get(memberships, user.id, []) == [],
          do: {:user, user.id}

    own_spend = Credits.spend_by_subjects(own_subjects)
    own_limit_spend = Credits.spend_by_subjects(own_subjects, only_limit: true)
    own_topups = Credits.Topups.summaries(own_subjects)

    Map.new(users, fn user ->
      subject = {:user, user.id}

      case Map.get(memberships, user.id, []) do
        [] ->
          {user.id,
           own_credit(
             user,
             Map.get(own_spend, subject, Decimal.new(0)),
             Map.get(own_limit_spend, subject, Decimal.new(0)),
             Map.get(own_topups, subject)
           )}

        memberships ->
          {user.id, membership_credit(memberships, summaries)}
      end
    end)
  end

  # Usuario sin membresía: el sujeto es él mismo. Su techo es el propio
  # (habitualmente ninguno) y, si lo tiene, el gasto que lo consume y su
  # remanente salen de los logs — antes se fijaban a cero, así que un techo
  # propio sin membresía se leía como agotado. Los top-ups siguen siendo el
  # segundo camino cuando no hay techo.
  defp own_credit(user, spend, against_limit, topup) do
    limit = Credits.user_limit(user, nil)
    remaining_topup = (topup && topup.remaining_topup_usd) || Decimal.new(0)

    remaining_limit =
      case limit.limit_usd do
        nil -> nil
        limit_usd -> max_decimal(Decimal.sub(limit_usd, against_limit), Decimal.new(0))
      end

    %{
      limit_usd: limit.limit_usd,
      unlimited?: limit.unlimited?,
      spend_usd: spend,
      limit_spend_usd: against_limit,
      remaining_limit_usd: remaining_limit,
      topups: (topup && topup.topups) || [],
      remaining_topup_usd: remaining_topup,
      has_path?: Credits.has_path?(limit.unlimited?, remaining_limit, remaining_topup)
    }
  end

  # Usuario con presupuesto mensual: el resumen del motor (límite efectivo +
  # top-ups vigentes) de la membresía.
  defp membership_credit(memberships, summaries) do
    # El primer resumen con camino de gasto gana (normalmente hay uno: un
    # usuario pertenece a un solo presupuesto mensual).
    case Enum.find(Enum.map(memberships, & &1.id), &Map.has_key?(summaries, &1)) do
      nil ->
        %{
          limit_usd: nil,
          unlimited?: false,
          spend_usd: Decimal.new(0),
          limit_spend_usd: Decimal.new(0),
          remaining_limit_usd: nil,
          topups: [],
          remaining_topup_usd: Decimal.new(0)
        }

      id ->
        Map.fetch!(summaries, id)
    end
  end

  # nils always sort last, in both directions (users without spend/groups data).
  defp compare_sort_values(a, b, direction) do
    case {a, b} do
      {nil, nil} ->
        true

      {nil, _} ->
        false

      {_, nil} ->
        true

      _ ->
        if direction == :asc, do: compare_vals(a, b) != :gt, else: compare_vals(a, b) != :lt
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

  ## Events — search -------------------------------------------------------
  @impl true
  def handle_event("search_users", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 1)
     |> load_users()}
  end

  ## Events — filter --------------------------------------------------------
  def handle_event("toggle_today_spend", _params, socket) do
    {:noreply,
     socket
     |> update(:filter_today_spend, &(!&1))
     |> assign(:page, 1)
     |> load_users()}
  end

  ## Events — paginado ------------------------------------------------------

  def handle_event("go_to_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:page, parse_page(page))
     |> load_users()}
  end

  def handle_event("change_per_page", %{"per_page" => per_page}, socket) do
    case parse_per_page(per_page) do
      {:ok, value} ->
        {:noreply,
         socket
         |> assign(:per_page, value)
         |> assign(:page, 1)
         |> load_users()}

      :error ->
        {:noreply, socket}
    end
  end

  ## Events — sort ----------------------------------------------------------
  def handle_event("sort_users", %{"field" => field}, socket) do
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
       |> load_users()}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Events — groups (read-only view modal; memberships are managed per group)

  def handle_event("view_groups", %{"id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)
    memberships = Accounts.list_group_members_for_user(user_id)
    group_ids = Enum.map(memberships, & &1.group_id)

    {:noreply,
     socket
     |> assign(:editing_groups_user_id, user_id)
     |> assign(:editing_groups_user_name, user.name || user.email)
     |> assign(:editing_group_ids, group_ids)}
  end

  def handle_event("cancel_edit_groups", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_groups_user_id, nil)
     |> assign(:editing_groups_user_name, nil)
     |> assign(:editing_group_ids, [])}
  end

  ## Events — API keys (N keys con label por usuario) -----------------------

  # Las keys de un usuario se cargan solo al abrir su modal: el listado de
  # usuarios no paga N+1 por cada fila.
  def handle_event("manage_keys", %{"id" => user_id}, socket) do
    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Usuario no encontrado.")}

      user ->
        {:noreply,
         socket
         |> assign(:keys_user_id, user.id)
         |> assign(:keys_user_name, user.name || user.email)
         |> assign(:new_key_token, nil)
         |> load_user_keys(user.id)}
    end
  end

  def handle_event("cancel_manage_keys", _params, socket) do
    {:noreply,
     socket
     |> assign(:keys_user_id, nil)
     |> assign(:keys_user_name, nil)
     |> assign(:keys, [])
     |> assign(:keys_spend, %{})
     |> assign(:new_key_token, nil)}
  end

  def handle_event("create_key", %{"key" => key_params}, socket) do
    user_id = socket.assigns.keys_user_id

    if user_id do
      {token, key_hash, key_prefix} = Accounts.generate_api_key_material()

      attrs = %{
        "subject_type" => "member",
        "user_id" => user_id,
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
            "user_id" => user_id
          })

          {:noreply,
           socket
           |> assign(:new_key_token, token)
           |> put_flash(:info, "Clave creada. Cópiala ahora: no se vuelve a mostrar.")
           |> load_user_keys(user_id)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "No se pudo crear la clave.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke_user_key", %{"key-id" => api_key_id}, socket) do
    with %{} = api_key <- Accounts.get_api_key(api_key_id),
         true <- api_key.user_id == socket.assigns.keys_user_id do
      case Accounts.revoke_api_key(api_key) do
        {:ok, _} ->
          audit(socket, "api_key.revoke", "api_key", api_key.id, %{
            "label" => api_key.label,
            "user_id" => api_key.user_id
          })

          {:noreply,
           socket
           |> put_flash(:info, "Clave revocada.")
           |> load_user_keys(socket.assigns.keys_user_id)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Clave no encontrada.")}
    end
  end

  def handle_event("dismiss_new_key_token", _params, socket) do
    {:noreply, assign(socket, :new_key_token, nil)}
  end

  # Limpia las sticky routes del USUARIO (todas sus keys): su próxima petición
  # re-evalúa proveedores en vez de quedarse pegado a uno degradado.
  def handle_event("clear_user_sticky_routes", %{"id" => user_id}, socket) do
    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Usuario no encontrado.")}

      user ->
        Accounts.clear_user_sticky_routes(user_id)

        audit(socket, "routing.clear_sticky", "user", user_id, %{"email" => user.email})

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Sticky routes limpiadas para #{user.name || user.email}. Su próxima petición se re-ruteará."
         )
         |> load_user_keys(user_id)}
    end
  end

  def handle_event("new_user", _params, socket) do
    changeset = User.admin_create_changeset(%User{}, %{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :user))
     |> assign(:editing_user_id, :new)
     |> assign(:form_mode, :create)}
  end

  def handle_event("edit_user", %{"id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)
    changeset = User.admin_update_changeset(user, %{})

    {:noreply,
     socket
     |> assign(:form, to_form(Map.put(changeset, :params, %{}), as: :user))
     |> assign(:editing_user_id, user.id)
     |> assign(:editing_user_sub_id, current_sub_id(user_id))
     |> assign(:form_mode, :edit)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_user_id, nil)
     |> assign(:editing_user_sub_id, nil)
     |> assign(:form_mode, nil)
     |> assign(:reset_user_id, nil)}
  end

  def handle_event("save_user", %{"user" => user_params}, socket) do
    case socket.assigns.form_mode do
      :create -> save_new_user(socket, user_params)
      :edit -> save_edit_user(socket, user_params)
    end
  end

  ## Events — reset password ---------------------------------------------

  def handle_event("reset_password", %{"id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)

    changeset = User.reset_password_changeset(user, %{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :user))
     |> assign(:reset_user_id, user.id)
     |> assign(:form_mode, :reset_password)}
  end

  def handle_event("save_password", %{"user" => user_params}, socket) do
    user_id = socket.assigns.reset_user_id
    user = Accounts.get_user!(user_id)

    case Accounts.reset_user_password(user, user_params) do
      {:ok, _user} ->
        audit(socket, "user.reset_password", "user", user.id, %{"email" => user.email})

        {:noreply,
         socket
         |> put_flash(:info, "Contraseña actualizada.")
         |> assign(:form, nil)
         |> assign(:reset_user_id, nil)
         |> assign(:form_mode, nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
    end
  end

  ## Events — suspend/activate -------------------------------------------

  def handle_event("toggle_status", %{"id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)

    if root_admin?(user) do
      {:noreply, put_flash(socket, :error, "No se puede suspender al administrador principal.")}
    else
      new_status = if user.status == "active", do: "suspended", else: "active"

      case Accounts.admin_update_user(user, %{"status" => new_status}) do
        {:ok, _} ->
          audit(socket, "user.toggle_status", "user", user.id, %{
            "email" => user.email,
            "status" => new_status
          })

          msg = if new_status == "active", do: "Usuario activado.", else: "Usuario suspendido."
          {:noreply, socket |> put_flash(:info, msg) |> load_users()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo cambiar el estado.")}
      end
    end
  end

  ## Events — delete user -------------------------------------------------

  def handle_event("open_delete_modal", %{"id" => user_id, "email" => email}, socket) do
    {:noreply,
     socket
     |> assign(:delete_target_id, user_id)
     |> assign(:delete_target_email, email)
     |> push_event("open_modal", %{id: "delete-user-modal"})}
  end

  def handle_event("confirm_delete_user", %{"id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)
    current_user = socket.assigns.current_user

    cond do
      root_admin?(user) ->
        {:noreply,
         socket
         |> put_flash(:error, "No se puede eliminar al administrador principal.")
         |> assign(:delete_target_id, nil)
         |> assign(:delete_target_email, nil)
         |> push_event("close_modal", %{id: "delete-user-modal"})}

      user.id == current_user.id ->
        {:noreply,
         socket
         |> put_flash(:error, "No puedes eliminar tu propia cuenta.")
         |> assign(:delete_target_id, nil)
         |> assign(:delete_target_email, nil)
         |> push_event("close_modal", %{id: "delete-user-modal"})}

      true ->
        case Accounts.delete_user(user) do
          {:ok, _} ->
            audit(socket, "user.delete", "user", user.id, %{"email" => user.email})

            {:noreply,
             socket
             |> put_flash(:info, "Usuario eliminado permanentemente. Toda su data fue borrada.")
             |> assign(:delete_target_id, nil)
             |> assign(:delete_target_email, nil)
             |> push_event("close_modal", %{id: "delete-user-modal"})
             |> load_users()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo eliminar el usuario.")}
        end
    end
  end

  ## Template helpers ------------------------------------------------------

  # Keys activas del usuario + consumo por key (una sola query por lote).
  defp load_user_keys(socket, user_id) do
    keys = Accounts.list_api_keys_for_user(user_id)
    spend = Accounts.spend_by_api_key(Enum.map(keys, & &1.id))

    socket
    |> assign(:keys, keys)
    |> assign(:keys_spend, spend)
  end

  # Params del paginador: un valor inválido no debe romper el evento; la
  # página se recorta después en `load_users/1`.
  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp parse_per_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> if n in @per_page_options, do: {:ok, n}, else: :error
      _ -> :error
    end
  end

  defp parse_per_page(_value), do: :error

  defp to_sort_field(field) when is_binary(field) do
    {:ok, String.to_existing_atom(field)}
  rescue
    ArgumentError -> :error
  end

  defp toggle_sort_direction(:asc), do: :desc
  defp toggle_sort_direction(:desc), do: :asc

  # Text-ish columns start asc; numeric/date columns start desc (most useful
  # first: biggest spenders, newest users). Crédito: desc = más consumo primero.
  defp default_direction_for(field)
       when field in [:credit, :monthly_spend, :total_spend, :inserted_at],
       do: :desc

  defp default_direction_for(_), do: :asc

  # Gasto del mes de un usuario: ausente en el agregado = no gastó (los usuarios
  # sin membresía no aparecen), no un dato desconocido. Un sujeto sin requests
  # tiene que leerse «$0.00», no «—».
  defp user_monthly_spend(spend_by_user, user_id) do
    case Map.get(spend_by_user, user_id) do
      %{real_monthly_usd: %Decimal{} = spend} -> spend
      _ -> Decimal.new(0)
    end
  end

  defp save_new_user(socket, user_params) do
    {sub_id, user_params} = Map.pop(user_params, "sub_id", nil)
    sub_id = if sub_id in ["", nil], do: nil, else: sub_id

    case Accounts.admin_create_user(user_params) do
      {:ok, user} ->
        audit(socket, "user.create", "user", user.id, %{
          "email" => user.email,
          "global_role" => user.global_role
        })

        # Un usuario pertenece a UN solo presupuesto mensual: es el sujeto que
        # le aporta su límite mensual heredado. Se crea la membresía + una key
        # inicial (la key cuelga del usuario: N keys con label).
        result =
          if sub_id do
            with {:ok, member} <-
                   Accounts.create_group_member(%{
                     user_id: user.id,
                     group_id: sub_id,
                     status: "active"
                   }) do
              create_initial_key(user, member)
            end
          end

        case result do
          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(
               :warning,
               "Usuario creado pero el presupuesto no se pudo asignar: #{format_errors(changeset)}"
             )
             |> assign(:form, nil)
             |> assign(:editing_user_id, nil)
             |> assign(:form_mode, nil)
             |> load_users()}

          _ ->
            {:noreply,
             socket
             |> put_flash(:info, "Usuario creado.")
             |> assign(:form, nil)
             |> assign(:editing_user_id, nil)
             |> assign(:form_mode, nil)
             |> load_users()}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
    end
  end

  defp save_edit_user(socket, user_params) do
    user_id = socket.assigns.editing_user_id
    user = Accounts.get_user!(user_id)
    {sub_id, user_params} = Map.pop(user_params, "sub_id", nil)
    sub_id = if sub_id in ["", nil], do: nil, else: sub_id

    # Prevent removing admin from the root seed user
    user_params = protect_root_user(user, user_params)

    case Accounts.admin_update_user(user, user_params) do
      {:ok, updated} ->
        audit(socket, "user.update", "user", updated.id, %{
          "email" => updated.email,
          "changes" =>
            user_params
            |> Map.take([
              "name",
              "global_role",
              "status",
              "monthly_spend_limit_usd",
              "unlimited_spend",
              "default_concurrency_limit",
              "default_rpm_limit"
            ])
            |> Map.put("group_id", sub_id)
        })

        # El presupuesto mensual (antes perfil de límites/sub) se mueve, no se acumula: un
        # usuario tiene uno solo. `sync_user_sub/2` es el único punto que toca membresías.
        case Accounts.sync_user_sub(user_id, sub_id) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Usuario actualizado.")
             |> assign(:form, nil)
             |> assign(:editing_user_id, nil)
             |> assign(:editing_user_sub_id, nil)
             |> assign(:form_mode, nil)
             |> load_users()}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               "Usuario actualizado, pero el presupuesto no se pudo mover: #{reason}"
             )
             |> assign(:form, nil)
             |> assign(:editing_user_id, nil)
             |> assign(:editing_user_sub_id, nil)
             |> assign(:form_mode, nil)
             |> load_users()}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
    end
  end

  # Presupuesto mensual vigente del usuario (uno solo por la invariante de la DB).
  defp current_sub_id(user_id) do
    case Accounts.list_group_members_for_user(user_id) do
      [member | _] -> member.group_id
      [] -> nil
    end
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp create_initial_key(user, member) do
    {_token, key_hash, key_prefix} = Accounts.generate_api_key_material()

    case Accounts.create_api_key(%{
           "subject_type" => "member",
           "user_id" => user.id,
           "group_member_id" => member.id,
           "label" => "inicial",
           "key_hash" => key_hash,
           "key_prefix" => key_prefix,
           "status" => "active"
         }) do
      {:ok, _api_key} -> {:ok, member}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp root_admin?(%User{email: email}) do
    root_email = System.get_env("TOKENGATE_ADMIN_EMAIL") || "admin@tokengate.local"
    String.downcase(email) == String.downcase(root_email)
  end

  defp protect_root_user(%User{} = user, params) do
    if root_admin?(user) do
      # Force admin role for root user
      Map.put(params, "global_role", "admin")
    else
      params
    end
  end

  def role_badge("admin"), do: "badge-primary"
  def role_badge(_), do: "badge-ghost"

  def status_badge("active"), do: "badge-success"
  def status_badge("suspended"), do: "badge-error"

  def google_badge(%User{google_id: nil}), do: nil
  def google_badge(%User{google_id: _}), do: "Google"

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
          Usuarios
          <:subtitle>Gestión de usuarios del sistema</:subtitle>
          <:actions>
            <div class="flex items-center gap-3">
              <.admin_search
                event="search_users"
                value={@search_query}
                placeholder="Buscar por nombre o correo..."
                input_id="user-search"
              />
              <button
                phx-click="toggle_today_spend"
                class={[
                  "btn btn-sm",
                  @filter_today_spend && "btn-primary",
                  !@filter_today_spend && "btn-ghost"
                ]}
                id="toggle-today-spend"
              >
                <.icon name="hero-currency-dollar" class="w-4 h-4" /> Gasto hoy
              </button>
              <.button phx-click="new_user" id="new-user-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> Nuevo usuario
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- User form — create (modal) --%>
        <.admin_modal
          :if={@form && @form_mode == :create}
          id="user-create-modal"
          on_close="cancel_form"
        >
          <h2 class="text-lg font-semibold mb-4">Nuevo usuario</h2>
          <.form for={@form} id="user-form" phx-submit="save_user">
            <.input
              field={@form[:email]}
              type="email"
              label="Correo"
              placeholder="usuario@empresa.com"
            />
            <.input field={@form[:name]} type="text" label="Nombre" placeholder="Nombre completo" />
            <.input
              field={@form[:password]}
              type="password"
              label="Contraseña"
              hint="Mínimo 12 caracteres, debe incluir letras y números."
            />
            <.input
              field={@form[:global_role]}
              type="select"
              label="Rol"
              options={[{"Usuario", "user"}, {"Administrador", "admin"}]}
              prompt="Selecciona un rol"
            />
            <.input
              field={@form[:sub_id]}
              type="select"
              label={gettext("Monthly budget")}
              options={Enum.map(@all_groups, fn t -> {t.name, t.id} end)}
              prompt={gettext("No monthly budget")}
              hint="Un usuario pertenece a UN solo presupuesto mensual: su techo de gasto heredado sale de aquí."
            />
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
              <button type="submit" class="btn btn-primary btn-sm" id="save-user-btn">Crear</button>
            </div>
          </.form>
        </.admin_modal>

        <%!-- User form — edit (modal) --%>
        <.admin_modal
          :if={@form && @form_mode == :edit}
          id="user-edit-modal"
          on_close="cancel_form"
        >
          <h2 class="text-lg font-semibold mb-4">Editar usuario</h2>
          <.form for={@form} id="user-edit-form" phx-submit="save_user">
            <.input field={@form[:name]} type="text" label="Nombre" />
            <.input
              field={@form[:global_role]}
              type="select"
              label="Rol"
              options={[{"Usuario", "user"}, {"Administrador", "admin"}]}
            />
            <.input
              field={@form[:status]}
              type="select"
              label="Estado"
              options={[{"Activo", "active"}, {"Suspendido", "suspended"}]}
            />
            <%!-- Límites propios del usuario: primer eslabón de la regla
                 `propio || contenedor || default`. Vacío = hereda del perfil de límites. --%>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <.input
                field={@form[:default_concurrency_limit]}
                type="number"
                label="Concurrencia"
                hint="Límite absoluto; vacío = hereda del perfil de límites."
              />
              <.input
                field={@form[:default_rpm_limit]}
                type="number"
                label="RPM"
                hint="Límite absoluto; vacío = hereda del perfil de límites."
              />
            </div>
            <%!-- Select único: mover de presupuesto mensual reemplaza el anterior
                 (el viejo pierde key y logs del usuario en cascada). El valor
                 vigente sale de `editing_user_sub_id`: el changeset no trae
                 params de membresía. --%>
            <.input
              field={@form[:sub_id]}
              type="select"
              label={gettext("Monthly budget")}
              options={Enum.map(@all_groups, fn t -> {t.name, t.id} end)}
              prompt={gettext("No monthly budget")}
              value={@editing_user_sub_id}
              hint="Un usuario pertenece a UN solo presupuesto mensual. Cambiarlo reemplaza el anterior."
            />
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
              <button type="submit" class="btn btn-primary btn-sm" id="update-user-btn">Guardar</button>
            </div>
          </.form>
        </.admin_modal>

        <%!-- User form — reset password (modal) --%>
        <.admin_modal
          :if={@form && @form_mode == :reset_password}
          id="user-reset-modal"
          on_close="cancel_form"
        >
          <h2 class="text-lg font-semibold mb-4">Restablecer contraseña</h2>
          <.form for={@form} id="user-reset-form" phx-submit="save_password">
            <.input
              field={@form[:password]}
              type="password"
              label="Nueva contraseña"
              hint="Mínimo 12 caracteres, debe incluir letras y números."
            />
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
              <button type="submit" class="btn btn-primary btn-sm" id="reset-pwd-btn">Restablecer</button>
            </div>
          </.form>
        </.admin_modal>

        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <table class="table table-sm">
            <thead>
              <tr>
                <%!-- Orden: identidad → campos QUE COMPARTE con Servicios (mismo
                     orden en ambas tablas) → resto de campos propios → Creado →
                     acciones. --%>
                <th>
                  <.sort_button
                    event="sort_users"
                    field={:name}
                    label="Usuario"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>Claves</th>
                <th>
                  <.sort_button
                    event="sort_users"
                    field={:credit}
                    label="Límite mensual (mes UTC)"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th class="text-right">
                  <.sort_button
                    event="sort_users"
                    field={:monthly_spend}
                    label="Gasto mensual"
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th class="text-right">
                  <.sort_button
                    event="sort_users"
                    field={:total_spend}
                    label="Gasto total"
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th>
                  <.sort_button
                    event="sort_users"
                    field={:role}
                    label="Rol"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>
                  <.sort_button
                    event="sort_users"
                    field={:status}
                    label="Estado"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>
                  <.sort_button
                    event="sort_users"
                    field={:groups}
                    label="Perfiles de límites"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>Google</th>
                <th>
                  <.sort_button
                    event="sort_users"
                    field={:inserted_at}
                    label="Creado"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th></th>
              </tr>
            </thead>
            <tbody id="users" phx-update="stream">
              <tr :for={{id, user} <- @streams.users} id={id}>
                <.user_row
                  user={user}
                  user_groups={@user_groups}
                  spend_by_user={@spend_by_user}
                  total_spend_by_user={@total_spend_by_user}
                  users_credit={@users_credit}
                  keys_counts={@keys_counts}
                  current_user={@current_user}
                  timezone={@timezone}
                />
              </tr>
            </tbody>
          </table>
          <.admin_empty_state
            :if={@users_empty?}
            id="users-empty"
            icon="hero-users"
            message="No hay usuarios todavía."
          />
          <.admin_pagination
            id="users-pagination"
            page={@page}
            per_page={@per_page}
            total={@total_count}
            total_pages={@total_pages}
            per_page_options={@per_page_options}
          />
        </div>
      </div>

      <%!-- Keys modal — N claves con etiqueta (mismo panel que Servicios) --%>
      <.admin_modal
        :if={@keys_user_id}
        id="user-keys-modal"
        on_close="cancel_manage_keys"
        width="max-w-2xl"
      >
        <h2 class="text-lg font-semibold mb-1">
          Claves API de <span class="text-primary">{@keys_user_name}</span>
        </h2>
        <p class="text-xs text-base-content/50 mb-4">
          Un usuario puede tener varias claves activas, cada una con su etiqueta.
        </p>

        <.keys_panel
          subject_kind="user"
          subject_id={@keys_user_id}
          keys={@keys}
          spend={@keys_spend}
          new_token={@new_key_token}
          create_event="create_key"
          revoke_event="revoke_user_key"
          dismiss_event="dismiss_new_key_token"
          sticky_event="clear_user_sticky_routes"
          empty_text="Este usuario no tiene claves activas."
        />

        <div class="flex gap-2 mt-4 justify-end">
          <button type="button" phx-click="cancel_manage_keys" class="btn btn-ghost btn-sm">
            Cerrar
          </button>
        </div>
      </.admin_modal>

      <%!-- Groups view modal — read-only; memberships are managed in Perfiles de límites → Miembros --%>
      <.admin_modal
        :if={@editing_groups_user_id}
        id="user-groups-modal"
        on_close="cancel_edit_groups"
        width="max-w-md"
      >
        <h2 class="text-lg font-semibold mb-4">
          Perfiles de límites de <span class="text-primary">{@editing_groups_user_name}</span>
        </h2>
        <div class="space-y-2">
          <%= for group <- @all_groups do %>
            <div class="flex items-center justify-between p-2 rounded-lg bg-base-200/50">
              <div class="flex items-center gap-2">
                <.icon
                  name={
                    if group.id in @editing_group_ids,
                      do: "hero-check-circle",
                      else: "hero-minus-circle"
                  }
                  class={
                    if group.id in @editing_group_ids,
                      do: "w-4 h-4 text-success",
                      else: "w-4 h-4 text-base-content/30"
                  }
                />
                <span class={[
                  "text-sm",
                  if(group.id in @editing_group_ids, do: "", else: "text-base-content/40")
                ]}>
                  {group.name}
                </span>
              </div>
              <%= if group.id in @editing_group_ids do %>
                <.link
                  navigate={~p"/budget/profiles/#{group}/members"}
                  class="btn btn-xs btn-ghost"
                  title="Gestionar membresías del perfil de límites"
                >
                  Miembros
                </.link>
              <% end %>
            </div>
          <% end %>
          <%= if @all_groups == [] do %>
            <p class="text-sm text-base-content/50 py-2">No hay perfiles de límites creados.</p>
          <% end %>
        </div>
        <p class="text-xs text-base-content/40 mt-3">
          Las membresías se gestionan desde <strong>Perfiles de límites → Miembros</strong>
          de cada perfil.
        </p>
        <div class="flex gap-2 mt-2 justify-end">
          <button type="button" phx-click="cancel_edit_groups" class="btn btn-primary btn-sm">
            Cerrar
          </button>
        </div>
      </.admin_modal>

      <%!-- Delete confirmation modal — warns about irreversible data loss --%>
      <.admin_delete_modal
        id="delete-user-modal"
        title="Eliminar usuario"
        target_label={@delete_target_email}
        target_span_id="delete-user-email"
        confirm_event="confirm_delete_user"
        confirm_value={@delete_target_id}
        confirm_button_id="confirm-delete-user"
        cancel_button_id="cancel-delete-user"
        warning_intro="Se borrará permanentemente toda su data:"
        warning_items={[
          "Membresías de perfiles de límites",
          "Claves API",
          "Todo el historial de consumo (request_logs)",
          "Los logs de auditoría perderán la atribución al usuario"
        ]}
      />
    </Layouts.dashboard>
    """
  end

  defp initials(%User{email: email}) when is_binary(email) do
    case String.split(email, "@") do
      [name | _] -> name |> String.slice(0, 2) |> String.upcase()
      _ -> "—"
    end
  end

  defp initials(_), do: "—"

  ## Credit helpers ------------------------------------------------------------

  # Remanente del techo: nunca negativo (un gasto por encima del techo —top-ups
  # o un techo bajado a mitad de ciclo— deja 0, no un saldo en contra).
  defp max_decimal(a, b), do: if(Decimal.compare(a, b) == :lt, do: b, else: a)

  ## Components ---------------------------------------------------------------

  attr :user, :map, required: true
  attr :user_groups, :map, required: true
  attr :spend_by_user, :map, required: true
  attr :total_spend_by_user, :map, required: true
  attr :users_credit, :map, required: true
  attr :keys_counts, :map, required: true
  attr :current_user, :map, required: true
  attr :timezone, :string, required: true

  defp user_row(assigns) do
    ~H"""
    <td>
      <.admin_identity initials={initials(@user)} title={@user.name} subtitle={@user.email} />
    </td>
    <td>
      <.keys_badge
        subject_id={@user.id}
        count={Map.get(@keys_counts, @user.id, 0)}
        open_event="manage_keys"
      />
    </td>
    <td id={"credit-#{@user.id}"} class="min-w-[150px]">
      <.budget_cell credit={Map.get(@users_credit, @user.id)} />
    </td>
    <td id={"spend-#{@user.id}"} class="text-right">
      <div class="text-xs font-mono">
        ${format_usd(user_monthly_spend(@spend_by_user, @user.id))}
      </div>
    </td>
    <td id={"total-spend-#{@user.id}"} class="text-right">
      <div class="text-xs font-mono">
        ${format_usd(Map.get(@total_spend_by_user, @user.id, Decimal.new(0)))}
      </div>
    </td>
    <td>
      <span class={["badge", "badge-sm", role_badge(@user.global_role)]}>{@user.global_role}</span>
    </td>
    <td>
      <span class={["badge", "badge-sm", status_badge(@user.status)]}>
        {if @user.status == "active", do: "Activo", else: "Suspendido"}
      </span>
    </td>
    <td>
      <div class="flex flex-wrap items-center gap-1">
        <%= for group <- Map.get(@user_groups, @user.id, []) do %>
          <span class="badge badge-xs badge-outline">{group.name}</span>
        <% end %>
        <button
          phx-click="view_groups"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"groups-#{@user.id}"}
          title="Ver perfiles de límites del usuario"
        >
          <.icon name="hero-eye" class="w-3 h-3" />
        </button>
      </div>
    </td>
    <td>
      <%= if google_badge(@user) do %>
        <span class="badge badge-sm badge-ghost"><.icon name="hero-globe-alt" class="w-3 h-3" />
        Google</span>
      <% else %>
        <span class="text-xs text-base-content/30">—</span>
      <% end %>
    </td>
    <td class="text-xs text-base-content/50">
      {format_date(@user.inserted_at, @timezone)}
    </td>
    <td>
      <div class="flex gap-1">
        <.link
          navigate={~p"/stats/users/#{@user.id}"}
          class="btn btn-xs btn-ghost"
          id={"stats-#{@user.id}"}
          title="Ver stats consolidados de este usuario"
          aria-label="Ver stats del usuario"
        >
          <.icon name="hero-chart-bar" class="w-3 h-3" />
        </.link>
        <button
          phx-click="edit_user"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"edit-#{@user.id}"}
          title="Editar usuario"
          aria-label="Editar usuario"
        >
          <.icon name="hero-pencil" class="w-3 h-3" />
        </button>
        <button
          phx-click="reset_password"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"pwd-#{@user.id}"}
          title="Restablecer contraseña"
          aria-label="Restablecer contraseña"
        >
          <.icon name="hero-arrow-path" class="w-3 h-3" />
        </button>
        <.link
          :if={@user.id != @current_user.id && !root_admin?(@user)}
          href={~p"/impersonate/#{@user.id}"}
          method="post"
          class="btn btn-xs btn-ghost"
          id={"impersonate-#{@user.id}"}
          data-confirm={"¿Ver el dashboard como #{@user.email}?"}
          title="Ver como este usuario"
          aria-label="Ver como este usuario"
        >
          <.icon name="hero-identification" class="w-3 h-3" />
        </.link>
        <button
          phx-click="toggle_status"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"status-#{@user.id}"}
          title={if @user.status == "active", do: "Suspender usuario", else: "Activar usuario"}
          aria-label={if @user.status == "active", do: "Suspender usuario", else: "Activar usuario"}
          data-confirm={
            if @user.status == "active",
              do: "¿Suspender usuario?",
              else: "¿Activar usuario?"
          }
        >
          <.icon
            name={if @user.status == "active", do: "hero-lock-closed", else: "hero-lock-open"}
            class="w-3 h-3"
          />
        </button>
        <%!-- Delete button: opens modal, not data-confirm (too destructive) --%>
        <button
          :if={@user.id != @current_user.id && !root_admin?(@user)}
          phx-click="open_delete_modal"
          phx-value-id={@user.id}
          phx-value-email={@user.email}
          class="btn btn-xs btn-ghost text-error"
          id={"delete-#{@user.id}"}
          title="Eliminar usuario"
          aria-label="Eliminar usuario"
        >
          <.icon name="hero-trash" class="w-3 h-3" />
        </button>
      </div>
    </td>
    """
  end
end
