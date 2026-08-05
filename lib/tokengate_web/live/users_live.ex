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

  alias Tokengate.Accounts
  alias Tokengate.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Usuarios · Tokengate")
      |> stream_configure(:users, dom_id: &stream_dom_id/1)
      |> assign(:form, nil)
      |> assign(:editing_user_id, nil)
      |> assign(:reset_user_id, nil)
      |> assign(:form_mode, nil)
      |> assign(:delete_target_id, nil)
      |> assign(:delete_target_email, nil)
      |> assign(:all_teams, Accounts.list_teams())
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:search_query, "")
      |> assign(:sort_field, :name)
      |> assign(:sort_direction, :asc)
      |> assign(:editing_teams_user_id, nil)
      |> assign(:editing_teams_user_name, nil)
      |> assign(:editing_team_ids, [])
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
  # user plus the lookup assigns (spend maps, team map) and returns a
  # comparable value.
  @sort_columns ~w(name role status teams monthly_spend total_spend inserted_at)a

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

    spend_by_user = Tokengate.Budgets.spend_by_user(timezone)
    total_spend_by_user = Tokengate.Logs.total_spend_by_user()
    user_teams = load_user_teams(filtered)

    sort_ctx = %{
      spend_by_user: spend_by_user,
      total_spend_by_user: total_spend_by_user,
      user_teams: user_teams
    }

    sorted =
      sort_users(filtered, socket.assigns.sort_field, socket.assigns.sort_direction, sort_ctx)

    socket
    |> assign(:spend_by_user, spend_by_user)
    |> assign(:total_spend_by_user, total_spend_by_user)
    |> assign(:user_teams, user_teams)
    |> stream(:users, build_grouped_rows(sorted, user_teams), reset: true)
  end

  defp load_user_teams(users) do
    users
    |> Enum.map(& &1.id)
    |> Accounts.list_teams_by_user_ids()
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

  defp sort_value(user, :teams, ctx) do
    case Map.get(ctx.user_teams, user.id, []) do
      [] -> ""
      teams -> teams |> Enum.map(&String.downcase(&1.name)) |> Enum.join(", ")
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

  # nils always sort last, in both directions (users without spend/teams data).
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

  ## Team grouping -----------------------------------------------------------

  # Stream dom_ids: a user appears once per team they belong to, so the row id
  # is namespaced per group; group header rows get their own prefix.
  defp stream_dom_id({:group, %{id: id}}), do: "group-#{id}"
  defp stream_dom_id({:user, %{id: id}, group_id}), do: "user-#{id}-#{group_id}"

  # Builds the stream rows: one {:group, team} header row per team followed by
  # its {:user, user, group_id} rows. A user appears in every team they belong
  # to (intentional — the admin sees the full roster per team). Users with no
  # membership land in the trailing "Sin equipo" group. Teams whose members
  # were all filtered out by the search are omitted.
  defp build_grouped_rows(sorted_users, user_teams) do
    team_names_by_id = Map.new(Tokengate.Accounts.list_teams(), &{&1.id, &1.name})

    users_by_team_id =
      Enum.reduce(sorted_users, %{}, fn user, acc ->
        teams = Map.get(user_teams, user.id, [])

        Enum.reduce(teams, acc, fn team, acc2 ->
          Map.update(acc2, team.id, [user], &[user | &1])
        end)
      end)

    ordered_team_ids =
      users_by_team_id
      |> Map.keys()
      |> Enum.sort_by(fn team_id -> String.downcase(Map.get(team_names_by_id, team_id, "")) end)

    grouped =
      Enum.flat_map(ordered_team_ids, fn team_id ->
        # Members were prepended during accumulation — reverse to restore the
        # sorted order from sorted_users.
        members = Enum.reverse(users_by_team_id[team_id])

        [
          {:group,
           %{id: team_id, name: Map.get(team_names_by_id, team_id, "—"), count: length(members)}}
        ] ++
          Enum.map(members, &{:user, &1, team_id})
      end)

    orphans = Enum.filter(sorted_users, fn u -> Map.get(user_teams, u.id, []) == [] end)

    if orphans == [] do
      grouped
    else
      grouped ++
        [{:group, %{id: "none", name: "Sin equipo", count: length(orphans)}}] ++
        Enum.map(orphans, &{:user, &1, "none"})
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

  ## Events — edit teams --------------------------------------------------
  def handle_event("edit_teams", %{"id" => user_id}, socket) do
    user = Accounts.get_user!(user_id)
    memberships = Accounts.list_team_members_for_user(user_id)
    team_ids = Enum.map(memberships, & &1.team_id)

    {:noreply,
     socket
     |> assign(:editing_teams_user_id, user_id)
     |> assign(:editing_teams_user_name, user.name || user.email)
     |> assign(:editing_team_ids, team_ids)}
  end

  def handle_event("cancel_edit_teams", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_teams_user_id, nil)
     |> assign(:editing_teams_user_name, nil)
     |> assign(:editing_team_ids, [])}
  end

  def handle_event("save_teams", %{"team_ids" => team_ids}, socket) do
    user_id = socket.assigns.editing_teams_user_id
    user = Accounts.get_user!(user_id)
    team_ids = team_ids |> List.wrap() |> Enum.reject(&(&1 in ["", nil]))

    # Get current memberships
    current = Accounts.list_team_members_for_user(user_id)
    current_team_ids = Enum.map(current, & &1.team_id)

    # Remove memberships not in new list
    to_remove = current |> Enum.filter(&(&1.team_id not in team_ids))
    Enum.each(to_remove, &Accounts.delete_team_member/1)

    # Add new memberships
    to_add = team_ids -- current_team_ids

    Enum.each(to_add, fn team_id ->
      with {:ok, member} <-
             Accounts.create_team_member(%{
               user_id: user_id,
               team_id: team_id,
               team_role: "user",
               status: "active"
             }),
           {:ok, _api_key, _token} <- Accounts.replace_api_key(member) do
        :ok
      end
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Equipos actualizados para #{user.name || user.email}.")
     |> assign(:editing_teams_user_id, nil)
     |> assign(:editing_teams_user_name, nil)
     |> assign(:editing_team_ids, [])
     |> load_users()}
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
  # first: biggest spenders, newest users).
  defp default_direction_for(field) when field in [:monthly_spend, :total_spend, :inserted_at],
    do: :desc

  defp default_direction_for(_), do: :asc

  defp fmt_money(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  defp save_new_user(socket, user_params) do
    {team_ids, user_params} = Map.pop(user_params, "team_ids", [])
    team_ids = team_ids |> List.wrap() |> Enum.reject(&(&1 in ["", nil]))

    case Accounts.admin_create_user(user_params) do
      {:ok, user} ->
        # Create team memberships + API keys for each selected team
        results =
          Enum.map(team_ids, fn team_id ->
            with {:ok, member} <-
                   Accounts.create_team_member(%{
                     user_id: user.id,
                     team_id: team_id,
                     team_role: "user",
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
           |> put_flash(:info, "Usuario creado con #{length(team_ids)} equipo(s).")
           |> assign(:form, nil)
           |> assign(:editing_user_id, nil)
           |> assign(:form_mode, nil)
           |> assign(:all_teams, Accounts.list_teams())
           |> load_users()}
        else
          {:noreply,
           socket
           |> put_flash(
             :warning,
             "Usuario creado pero #{length(failed)} equipo(s) no se pudieron asignar."
           )
           |> assign(:form, nil)
           |> assign(:editing_user_id, nil)
           |> assign(:form_mode, nil)
           |> assign(:all_teams, Accounts.list_teams())
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
      {:ok, _user} ->
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
              <.form for={%{}} phx-change="search_users" phx-submit="search_users" id="search-form">
                <div class="relative">
                  <.icon
                    name="hero-magnifying-glass"
                    class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
                  />
                  <input
                    type="text"
                    name="q"
                    placeholder="Buscar por nombre o correo..."
                    value={@search_query}
                    phx-debounce="300"
                    class="input input-sm input-bordered pl-9 w-64"
                    id="user-search"
                  />
                </div>
              </.form>
              <.button phx-click="new_user" id="new-user-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> Nuevo usuario
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- User form — create (modal) --%>
        <div
          :if={@form && @form_mode == :create}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
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
                  field={@form[:team_ids]}
                  type="select"
                  multiple
                  label="Equipos"
                  options={Enum.map(@all_teams, fn t -> {t.name, t.id} end)}
                  hint="Mantén Ctrl/Cmd para seleccionar múltiples equipos."
                />
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-user-btn">Crear</button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- User form — edit (modal) --%>
        <div
          :if={@form && @form_mode == :edit}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
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
            </div>
          </div>
        </div>

        <%!-- User form — reset password (modal) --%>
        <div
          :if={@form && @form_mode == :reset_password}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
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
            </div>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>
                  <.sort_button
                    field={:name}
                    label="Usuario"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>
                  <.sort_button
                    field={:role}
                    label="Rol"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>
                  <.sort_button
                    field={:status}
                    label="Estado"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>
                  <.sort_button
                    field={:teams}
                    label="Equipos"
                    current={@sort_field}
                    direction={@sort_direction}
                  />
                </th>
                <th>Google</th>
                <th class="text-right">
                  <.sort_button
                    field={:monthly_spend}
                    label="Gasto mensual"
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
                <th class="text-right">
                  <.sort_button
                    field={:total_spend}
                    label="Gasto total"
                    current={@sort_field}
                    direction={@sort_direction}
                    align="right"
                  />
                </th>
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
            <tbody id="users" phx-update="stream">
              <tr :for={{id, row} <- @streams.users} id={id}>
                <%= case row do %>
                  <% {:group, group} -> %>
                    <td colspan="9" class="bg-base-200/60 border-y border-base-300 py-2">
                      <div class="flex items-center gap-2">
                        <.icon name="hero-user-group" class="w-4 h-4 text-base-content/60" />
                        <span class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                          {group.name}
                        </span>
                        <span class="badge badge-xs badge-ghost">{group.count}</span>
                      </div>
                    </td>
                  <% {:user, user, group_id} -> %>
                    <.user_row
                      user={user}
                      group_id={group_id}
                      user_teams={@user_teams}
                      spend_by_user={@spend_by_user}
                      total_spend_by_user={@total_spend_by_user}
                      current_user={@current_user}
                      timezone={@timezone}
                    />
                <% end %>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Teams editing modal --%>
      <div
        :if={@editing_teams_user_id}
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
      >
        <div class="absolute inset-0 bg-black/50" phx-click="cancel_edit_teams" />
        <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-md">
          <div class="card-body p-6">
            <h2 class="text-lg font-semibold mb-4">
              Equipos de <span class="text-primary">{@editing_teams_user_name}</span>
            </h2>
            <.form for={%{}} phx-submit="save_teams" id="edit-teams-form">
              <div class="space-y-2">
                <%= for team <- @all_teams do %>
                  <label class="flex items-center gap-3 p-2 rounded-lg hover:bg-base-200 cursor-pointer">
                    <input
                      type="checkbox"
                      name="team_ids[]"
                      value={team.id}
                      checked={team.id in @editing_team_ids}
                      class="checkbox checkbox-sm checkbox-primary"
                    />
                    <span class="text-sm">{team.name}</span>
                  </label>
                <% end %>
                <%= if @all_teams == [] do %>
                  <p class="text-sm text-base-content/50 py-2">No hay equipos creados.</p>
                <% end %>
              </div>
              <div class="flex gap-2 mt-4 justify-end">
                <button type="button" phx-click="cancel_edit_teams" class="btn btn-ghost btn-sm">
                  Cancelar
                </button>
                <button type="submit" class="btn btn-primary btn-sm" id="save-teams-btn">
                  Guardar
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>

      <%!-- Delete confirmation modal — warns about irreversible data loss --%>
      <dialog id="delete-user-modal" class="modal" phx-hook="Modal">
        <div class="modal-box max-w-md">
          <h3 class="text-lg font-bold text-error flex items-center gap-2">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" /> Eliminar usuario
          </h3>
          <div class="py-4 space-y-3">
            <p class="text-sm">
              ¿Seguro que quieres eliminar a <span class="font-semibold" id="delete-user-email">{@delete_target_email}</span>?
            </p>
            <div class="alert alert-warning text-sm">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
              <div>
                <p class="font-semibold">Esta acción es irreversible.</p>
                <p class="mt-1">
                  Se borrará permanentemente toda su data:
                </p>
                <ul class="mt-1 list-disc list-inside space-y-0.5 text-xs">
                  <li>Membresías de equipos</li>
                  <li>Claves API</li>
                  <li>Todo el historial de consumo (request_logs)</li>
                  <li>Los logs de auditoría perderán la atribución al usuario</li>
                </ul>
              </div>
            </div>
          </div>
          <div class="modal-action">
            <form method="dialog">
              <button class="btn btn-ghost btn-sm" id="cancel-delete-user">Cancelar</button>
            </form>
            <button
              phx-click="confirm_delete_user"
              phx-value-id={@delete_target_id}
              class="btn btn-error btn-sm"
              id="confirm-delete-user"
            >
              <.icon name="hero-trash" class="w-4 h-4" /> Sí, eliminar permanentemente
            </button>
          </div>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button>close</button>
        </form>
      </dialog>
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

  ## Components ---------------------------------------------------------------

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :current, :atom, required: true
  attr :direction, :atom, required: true
  attr :align, :string, default: "left"

  defp sort_button(assigns) do
    ~H"""
    <button
      phx-click="sort_users"
      phx-value-field={@field}
      class={[
        "flex items-center gap-1 hover:text-primary",
        @align == "right" && "justify-end w-full"
      ]}
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

  attr :user, :map, required: true
  attr :group_id, :string, required: true
  attr :user_teams, :map, required: true
  attr :spend_by_user, :map, required: true
  attr :total_spend_by_user, :map, required: true
  attr :current_user, :map, required: true
  attr :timezone, :string, required: true

  defp user_row(assigns) do
    ~H"""
    <td>
      <div class="flex items-center gap-3">
        <div class="avatar avatar-placeholder">
          <div class="w-8 rounded-full bg-primary text-primary-content">
            <span class="text-xs font-semibold">{initials(@user)}</span>
          </div>
        </div>
        <div>
          <p class="font-medium text-sm">{@user.name}</p>
          <p class="text-xs text-base-content/50">{@user.email}</p>
        </div>
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
        <%= for team <- Map.get(@user_teams, @user.id, []) do %>
          <span class="badge badge-xs badge-outline">{team.name}</span>
        <% end %>
        <button
          phx-click="edit_teams"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"teams-#{@user.id}-#{@group_id}"}
          title="Editar equipos"
        >
          <.icon name="hero-pencil" class="w-3 h-3" />
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
    <td id={"spend-#{@user.id}-#{@group_id}"} class="text-right">
      <%= case Map.get(@spend_by_user, @user.id) do %>
        <% nil -> %>
          <span class="text-xs text-base-content/30">—</span>
        <% spend -> %>
          <div class={["text-xs font-mono", spend.exhausted? && "text-error font-semibold"]}>
            ${fmt_money(spend.monthly_usd)}
          </div>
          <%= if spend.exhausted? do %>
            <span class="badge badge-xs badge-error mt-0.5">sin crédito</span>
          <% end %>
      <% end %>
    </td>
    <td id={"total-spend-#{@user.id}-#{@group_id}"} class="text-right">
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
          id={"impersonate-#{@user.id}-#{@group_id}"}
          data-confirm={"¿Ver el dashboard como #{@user.email}?"}
          title="Ver como este usuario"
        >
          <.icon name="hero-eye" class="w-3 h-3" />
        </.link>
        <.link
          navigate={~p"/dashboard/users/#{@user.id}/stats"}
          class="btn btn-xs btn-ghost"
          id={"stats-#{@user.id}-#{@group_id}"}
          title="Ver stats consolidados de este usuario"
        >
          <.icon name="hero-chart-bar" class="w-3 h-3" />
        </.link>
        <button
          phx-click="edit_user"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"edit-#{@user.id}-#{@group_id}"}
        >
          <.icon name="hero-pencil" class="w-3 h-3" />
        </button>
        <button
          phx-click="reset_password"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"pwd-#{@user.id}-#{@group_id}"}
        >
          <.icon name="hero-key" class="w-3 h-3" />
        </button>
        <button
          phx-click="toggle_status"
          phx-value-id={@user.id}
          class="btn btn-xs btn-ghost"
          id={"status-#{@user.id}-#{@group_id}"}
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
          id={"delete-#{@user.id}-#{@group_id}"}
          title="Eliminar usuario"
        >
          <.icon name="hero-trash" class="w-3 h-3" />
        </button>
      </div>
    </td>
    """
  end
end
