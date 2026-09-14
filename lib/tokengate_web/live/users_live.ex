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

  alias Tokengate.Accounts
  alias Tokengate.Accounts.User
  alias Tokengate.Credits
  alias Tokengate.Metrics.DashboardCache

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

    # Crédito vigente por usuario (grants únicos: defaults de sus grupos +
    # subs directas, dedup de subs compartidas). Grants = 1 query por sub del
    # usuario; la clave incluye el conjunto de ids filtrados para no servir
    # entradas rancias (5s TTL) cuando el set cambia.
    credit_by_user =
      DashboardCache.fetch_or_compute(
        {:users_credit_by_user, Enum.map(filtered, & &1.id)},
        fn ->
          Map.new(filtered, &{&1.id, Credits.user_credit(&1.id)})
        end
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
      credit_by_user: credit_by_user
    }

    sorted =
      sort_users(filtered, socket.assigns.sort_field, socket.assigns.sort_direction, sort_ctx)

    socket
    |> assign(:spend_by_user, spend_by_user)
    |> assign(:total_spend_by_user, total_spend_by_user)
    |> assign(:user_groups, user_groups)
    |> assign(:credit_by_user, credit_by_user)
    |> assign(:users_empty?, sorted == [])
    |> stream(:users, sorted, reset: true)
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

  defp sort_value(user, :groups, ctx) do
    case Map.get(ctx.user_groups, user.id, []) do
      [] -> ""
      groups -> groups |> Enum.map(&String.downcase(&1.name)) |> Enum.join(", ")
    end
  end

  # Crédito restante (nil = sin crédito → tier 3, ordena último igual que nil).
  defp sort_value(user, :credit, ctx) do
    case Map.get(ctx.credit_by_user, user.id) do
      %{credited_micro: 0} -> nil
      %{remaining_micro: rem} -> rem
      _ -> nil
    end
  end

  defp sort_value(user, :monthly_spend, ctx) do
    case Map.get(ctx.spend_by_user, user.id) do
      nil -> nil
      spend -> spend.monthly_usd
    end
  end

  defp sort_value(user, :total_spend, ctx) do
    Map.get(ctx.total_spend_by_user, user.id)
  end

  defp sort_value(user, :inserted_at, _ctx), do: user.inserted_at

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
     |> load_users()}
  end

  ## Events — filter --------------------------------------------------------
  def handle_event("toggle_today_spend", _params, socket) do
    {:noreply,
     socket
     |> update(:filter_today_spend, &(!&1))
     |> load_users()}
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
     |> assign(:form, to_form(changeset, as: :user))
     |> assign(:editing_user_id, user.id)
     |> assign(:form_mode, :edit)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_user_id, nil)
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
        Tokengate.Auditing.audit(
          socket.assigns.current_user,
          "user.reset_password",
          "user",
          user.id,
          %{"email" => user.email}
        )

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
          Tokengate.Auditing.audit(
            socket.assigns.current_user,
            "user.toggle_status",
            "user",
            user.id,
            %{"email" => user.email, "status" => new_status}
          )

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
            Tokengate.Auditing.audit(
              socket.assigns.current_user,
              "user.delete",
              "user",
              user.id,
              %{"email" => user.email}
            )

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

  ## Template helpers -----------------------------------------------------

  defp to_sort_field(field) when is_binary(field) do
    {:ok, String.to_existing_atom(field)}
  rescue
    ArgumentError -> :error
  end

  defp toggle_sort_direction(:asc), do: :desc
  defp toggle_sort_direction(:desc), do: :asc

  # Text-ish columns start asc; numeric/date columns start desc (most useful
  # first: biggest spenders, newest users). Crédito: desc = más saldo primero.
  defp default_direction_for(field)
       when field in [:credit, :monthly_spend, :total_spend, :inserted_at],
       do: :desc

  defp default_direction_for(_), do: :asc

  defp fmt_money(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  defp save_new_user(socket, user_params) do
    {group_ids, user_params} = Map.pop(user_params, "group_ids", [])
    group_ids = group_ids |> List.wrap() |> Enum.reject(&(&1 in ["", nil]))

    case Accounts.admin_create_user(user_params) do
      {:ok, user} ->
        Tokengate.Auditing.audit(socket.assigns.current_user, "user.create", "user", user.id, %{
          "email" => user.email,
          "global_role" => user.global_role
        })

        # Create group memberships + API keys for each selected group
        results =
          Enum.map(group_ids, fn group_id ->
            with {:ok, member} <-
                   Accounts.create_group_member(%{
                     user_id: user.id,
                     group_id: group_id,
                     status: "active"
                   }),
                 {:ok, _api_key, _token} <- Accounts.replace_api_key(member) do
              {:ok, member}
            end
          end)

        failed = Enum.filter(results, &match?({:error, _}, &1))

        if failed == [] do
          {:noreply,
           socket
           |> put_flash(:info, "Usuario creado con #{length(group_ids)} grupo(s).")
           |> assign(:form, nil)
           |> assign(:editing_user_id, nil)
           |> assign(:form_mode, nil)
           |> assign(:all_groups, Accounts.list_groups())
           |> load_users()}
        else
          {:noreply,
           socket
           |> put_flash(
             :warning,
             "Usuario creado pero #{length(failed)} grupo(s) no se pudieron asignar."
           )
           |> assign(:form, nil)
           |> assign(:editing_user_id, nil)
           |> assign(:form_mode, nil)
           |> assign(:all_groups, Accounts.list_groups())
           |> load_users()}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
    end
  end

  defp save_edit_user(socket, user_params) do
    user_id = socket.assigns.editing_user_id
    user = Accounts.get_user!(user_id)

    # Prevent removing admin from the root seed user
    user_params = protect_root_user(user, user_params)

    case Accounts.admin_update_user(user, user_params) do
      {:ok, updated} ->
        Tokengate.Auditing.audit(
          socket.assigns.current_user,
          "user.update",
          "user",
          updated.id,
          %{
            "email" => updated.email,
            "changes" => Map.take(user_params, ["name", "global_role", "status"])
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, "Usuario actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_user_id, nil)
         |> assign(:form_mode, nil)
         |> load_users()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
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
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
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
              field={@form[:group_ids]}
              type="select"
              multiple
              label="Grupos"
              options={Enum.map(@all_groups, fn t -> {t.name, t.id} end)}
              hint="Mantén Ctrl/Cmd para seleccionar múltiples grupos."
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
                <th>
                  <.sort_button
                    event="sort_users"
                    field={:name}
                    label="Usuario"
                    current={@sort_field}
                    direction={@sort_direction}
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
                    label="Grupos"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>
                  <.sort_button
                    event="sort_users"
                    field={:credit}
                    label="Crédito"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>Google</th>
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
                  credit_by_user={@credit_by_user}
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
        </div>
      </div>

      <%!-- Groups view modal — read-only; memberships are managed in Grupos → Miembros --%>
      <.admin_modal
        :if={@editing_groups_user_id}
        id="user-groups-modal"
        on_close="cancel_edit_groups"
        width="max-w-md"
      >
        <h2 class="text-lg font-semibold mb-4">
          Grupos de <span class="text-primary">{@editing_groups_user_name}</span>
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
                  navigate={~p"/admin/groups/#{group}/members"}
                  class="btn btn-xs btn-ghost"
                  title="Gestionar membresías del grupo"
                >
                  Miembros
                </.link>
              <% end %>
            </div>
          <% end %>
          <%= if @all_groups == [] do %>
            <p class="text-sm text-base-content/50 py-2">No hay grupos creados.</p>
          <% end %>
        </div>
        <p class="text-xs text-base-content/40 mt-3">
          Las membresías se gestionan desde <strong>Grupos → Miembros</strong> de cada grupo.
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
          "Membresías de grupos",
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

  # Porcentaje consumido del crédito (nil cuando no hay crédito otorgado).
  defp credit_pct(%{credited_micro: 0}), do: nil

  defp credit_pct(%{credited_micro: c, consumed_micro: k}) when c > 0,
    do: Float.round(k / c * 100, 1)

  defp credit_pct(_), do: nil

  # Formatea micro-USD como USD.
  defp format_micro(micro) when is_integer(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
    |> Decimal.round(2, :half_up)
    |> Decimal.to_string(:normal)
  end

  defp credit_bar_width(nil), do: "width: 0%"

  defp credit_bar_width(pct) when is_number(pct), do: "width: #{min(pct, 100)}%"

  defp credit_bar_class(pct) when is_number(pct) do
    cond do
      pct >= 90 -> "bg-error"
      pct >= 70 -> "bg-warning"
      true -> "bg-success"
    end
  end

  defp credit_bar_class(_), do: "bg-base-300"

  ## Components ---------------------------------------------------------------

  attr :user, :map, required: true
  attr :user_groups, :map, required: true
  attr :spend_by_user, :map, required: true
  attr :total_spend_by_user, :map, required: true
  attr :credit_by_user, :map, required: true
  attr :current_user, :map, required: true
  attr :timezone, :string, required: true

  defp user_row(assigns) do
    ~H"""
    <td>
      <.admin_identity initials={initials(@user)} title={@user.name} subtitle={@user.email} />
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
          title="Ver grupos del usuario"
        >
          <.icon name="hero-eye" class="w-3 h-3" />
        </button>
      </div>
    </td>
    <td id={"credit-#{@user.id}"}>
      <%= case Map.get(@credit_by_user, @user.id) do %>
        <% nil -> %>
          <span class="text-xs text-base-content/30">—</span>
        <% %{has_credit?: false} -> %>
          <span class="badge badge-sm badge-ghost badge-outline">Sin crédito</span>
        <% %{credited_micro: 0} -> %>
          <span class="text-xs text-base-content/30">—</span>
        <% credit -> %>
          <div class="flex items-center gap-2">
            <span class="text-xs font-mono">
              ${format_micro(credit.remaining_micro)}
              <span class="text-base-content/40">/ ${format_micro(credit.credited_micro)}</span>
            </span>
            <% cpct = credit_pct(credit) %>
            <div class="w-16 h-1.5 rounded-full bg-base-200 overflow-hidden">
              <div
                class={["h-full rounded-full transition-all", credit_bar_class(cpct)]}
                style={credit_bar_width(cpct)}
              >
              </div>
            </div>
          </div>
      <% end %>
    </td>
    <td>
      <%= if google_badge(@user) do %>
        <span class="badge badge-sm badge-ghost"><.icon name="hero-globe-alt" class="w-3 h-3" />
        Google</span>
      <% else %>
        <span class="text-xs text-base-content/30">—</span>
      <% end %>
    </td>
    <td id={"spend-#{@user.id}"} class="text-right">
      <%= case Map.get(@spend_by_user, @user.id) do %>
        <% nil -> %>
          <span class="text-xs text-base-content/30">—</span>
        <% spend -> %>
          <div class="text-xs font-mono">
            ${fmt_money(spend.monthly_usd)}
          </div>
      <% end %>
    </td>
    <td id={"total-spend-#{@user.id}"} class="text-right">
      <%= case Map.get(@total_spend_by_user, @user.id) do %>
        <% nil -> %>
          <span class="text-xs text-base-content/30">—</span>
        <% total -> %>
          <div class="text-xs font-mono">
            ${fmt_money(total)}
          </div>
      <% end %>
    </td>
    <td class="text-xs text-base-content/50">
      {format_date(@user.inserted_at, @timezone)}
    </td>
    <td>
      <div class="flex gap-1">
        <.link
          :if={@user.id != @current_user.id && !root_admin?(@user)}
          href={~p"/impersonate/#{@user.id}"}
          method="post"
          class="btn btn-xs btn-ghost"
          id={"impersonate-#{@user.id}"}
          data-confirm={"¿Ver el dashboard como #{@user.email}?"}
          title="Ver como este usuario"
        >
          <.icon name="hero-eye" class="w-3 h-3" />
        </.link>
        <.link
          navigate={~p"/stats/users/#{@user.id}"}
          class="btn btn-xs btn-ghost"
          id={"stats-#{@user.id}"}
          title="Ver stats consolidados de este usuario"
        >
          <.icon name="hero-chart-bar" class="w-3 h-3" />
        </.link>
        <button
          phx-click="edit_user"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"edit-#{@user.id}"}
        >
          <.icon name="hero-pencil" class="w-3 h-3" />
        </button>
        <button
          phx-click="reset_password"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"pwd-#{@user.id}"}
        >
          <.icon name="hero-key" class="w-3 h-3" />
        </button>
        <button
          phx-click="toggle_status"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"status-#{@user.id}"}
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
        >
          <.icon name="hero-trash" class="w-3 h-3" />
        </button>
      </div>
    </td>
    """
  end
end
