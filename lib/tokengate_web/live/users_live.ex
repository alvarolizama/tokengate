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
      |> assign(:form, nil)
      |> assign(:editing_user_id, nil)
      |> assign(:reset_user_id, nil)
      |> assign(:form_mode, nil)
      |> assign(:is_admin, user && user.global_role == "admin")
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

  defp load_users(socket) do
    users = Accounts.list_users()

    socket
    |> assign(:spend_by_user, Tokengate.Budgets.spend_by_user())
    |> stream(:users, users, reset: true)
  end

  ## Events — create/edit user -------------------------------------------

  @impl true
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

  ## Template helpers -----------------------------------------------------

  defp fmt_money(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  defp save_new_user(socket, user_params) do
    case Accounts.admin_create_user(user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Usuario creado correctamente.")
         |> assign(:form, nil)
         |> assign(:editing_user_id, nil)
         |> assign(:form_mode, nil)
         |> load_users()}

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

  def format_date(datetime) do
    Calendar.strftime(datetime, "%d/%m/%Y")
  end

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
            <.button phx-click="new_user" id="new-user-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo usuario
            </.button>
          </:actions>
        </.header>

        <div
          :if={@form && @form_mode == :create}
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="user-form-card"
        >
          <div class="card-body">
            <h2 class="text-base font-semibold mb-2">Nuevo usuario</h2>
            <.form for={@form} id="user-form" phx-submit="save_user">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <.input
                  field={@form[:email]}
                  type="email"
                  label="Correo"
                  placeholder="usuario@empresa.com"
                />
                <.input field={@form[:name]} type="text" label="Nombre" placeholder="Nombre completo" />
              </div>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mt-3">
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
              </div>
              <div class="flex gap-2 mt-3">
                <button type="submit" class="btn btn-primary" id="save-user-btn">Crear</button>
                <button type="button" phx-click="cancel_form" class="btn btn-ghost">Cancelar</button>
              </div>
            </.form>
          </div>
        </div>

        <div
          :if={@form && @form_mode == :edit}
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="user-edit-card"
        >
          <div class="card-body">
            <h2 class="text-base font-semibold mb-2">Editar usuario</h2>
            <.form for={@form} id="user-edit-form" phx-submit="save_user">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <.input field={@form[:name]} type="text" label="Nombre" />
                <.input
                  field={@form[:global_role]}
                  type="select"
                  label="Rol"
                  options={[{"Usuario", "user"}, {"Administrador", "admin"}]}
                />
              </div>
              <div class="mt-3">
                <.input
                  field={@form[:status]}
                  type="select"
                  label="Estado"
                  options={[{"Activo", "active"}, {"Suspendido", "suspended"}]}
                />
              </div>
              <div class="flex gap-2 mt-3">
                <button type="submit" class="btn btn-primary" id="update-user-btn">Guardar</button>
                <button type="button" phx-click="cancel_form" class="btn btn-ghost">Cancelar</button>
              </div>
            </.form>
          </div>
        </div>

        <div
          :if={@form && @form_mode == :reset_password}
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="user-reset-card"
        >
          <div class="card-body">
            <h2 class="text-base font-semibold mb-2">Restablecer contraseña</h2>
            <.form for={@form} id="user-reset-form" phx-submit="save_password">
              <.input
                field={@form[:password]}
                type="password"
                label="Nueva contraseña"
                hint="Mínimo 12 caracteres, debe incluir letras y números."
              />
              <div class="flex gap-2 mt-3">
                <button type="submit" class="btn btn-primary" id="reset-pwd-btn">Restablecer</button>
                <button type="button" phx-click="cancel_form" class="btn btn-ghost">Cancelar</button>
              </div>
            </.form>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Usuario</th>
                <th>Rol</th>
                <th>Estado</th>
                <th>Google</th>
                <th>Gasto hoy / mes</th>
                <th>Creado</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="users" phx-update="stream">
              <tr :for={{id, user} <- @streams.users} id={id}>
                <td>
                  <div class="flex items-center gap-3">
                    <div class="avatar avatar-placeholder">
                      <div class="w-8 rounded-full bg-primary text-primary-content">
                        <span class="text-xs font-semibold">{initials(user)}</span>
                      </div>
                    </div>
                    <div>
                      <p class="font-medium text-sm">{user.name}</p>
                      <p class="text-xs text-base-content/50">{user.email}</p>
                    </div>
                  </div>
                </td>
                <td>
                  <span class={["badge", "badge-sm", role_badge(user.global_role)]}>{user.global_role}</span>
                </td>
                <td>
                  <span class={["badge", "badge-sm", status_badge(user.status)]}>{if user.status ==
                                                                                       "active",
                                                                                     do: "Activo",
                                                                                     else:
                                                                                       "Suspendido"}</span>
                </td>
                <td>
                  <%= if google_badge(user) do %>
                    <span class="badge badge-sm badge-ghost"><.icon
                      name="hero-globe-alt"
                      class="w-3 h-3"
                    /> Google</span>
                  <% else %>
                    <span class="text-xs text-base-content/30">—</span>
                  <% end %>
                </td>
                <td id={"spend-#{user.id}"}>
                  <%= case Map.get(@spend_by_user, user.id) do %>
                    <% nil -> %>
                      <span class="text-xs text-base-content/30">—</span>
                    <% spend -> %>
                      <div class={[
                        "text-xs font-mono",
                        spend.exhausted? && "text-error font-semibold"
                      ]}>
                        ${fmt_money(spend.daily_usd)} / ${fmt_money(spend.monthly_usd)}
                      </div>
                      <%= if spend.exhausted? do %>
                        <span class="badge badge-xs badge-error mt-0.5">sin crédito</span>
                      <% end %>
                  <% end %>
                </td>
                <td class="text-xs text-base-content/50">{format_date(user.inserted_at)}</td>
                <td>
                  <div class="flex gap-1">
                    <.link
                      :if={user.id != @current_user.id && !root_admin?(user)}
                      href={~p"/impersonate/#{user.id}"}
                      method="post"
                      class="btn btn-xs btn-ghost"
                      id={"impersonate-#{user.id}"}
                      data-confirm={"¿Ver el dashboard como #{user.email}?"}
                      title="Ver como este usuario"
                    >
                      <.icon name="hero-eye" class="w-3 h-3" />
                    </.link>
                    <button
                      phx-click="edit_user"
                      phx-value-id={user.id}
                      class="btn btn-xs btn-ghost"
                      id={"edit-#{user.id}"}
                    >
                      <.icon name="hero-pencil" class="w-3 h-3" />
                    </button>
                    <button
                      phx-click="reset_password"
                      phx-value-id={user.id}
                      class="btn btn-xs btn-ghost"
                      id={"pwd-#{user.id}"}
                    >
                      <.icon name="hero-key" class="w-3 h-3" />
                    </button>
                    <button
                      phx-click="toggle_status"
                      phx-value-id={user.id}
                      class="btn btn-xs btn-ghost"
                      id={"status-#{user.id}"}
                      data-confirm={
                        if user.status == "active",
                          do: "¿Suspender usuario?",
                          else: "¿Activar usuario?"
                      }
                    >
                      <.icon
                        name={
                          if user.status == "active", do: "hero-lock-closed", else: "hero-lock-open"
                        }
                        class="w-3 h-3"
                      />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
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
end
