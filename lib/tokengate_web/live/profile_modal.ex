defmodule TokengateWeb.ProfileModal do
  @moduledoc """
  Cuenta del usuario autenticado en un modal colgado del avatar del topbar:
  datos de la cuenta y cambio de contraseña propia (re-autenticando con la
  contraseña actual). Sustituye a la antigua página `/profile`.

  El disparador (avatar) y el `<dialog>` viven en el mismo LiveComponent para
  resolver sus eventos con `phx-target={@myself}`: el shell
  `Layouts.dashboard` lo comparten todas las LiveViews autenticadas y ninguna
  de ellas debe conocer este modal. El `id="profile-modal"` es el del
  componente (raíz) y el del diálogo es `profile-modal-dialog`.

  El `<dialog>` nativo (top layer, así el `backdrop-blur` del topbar no le
  afecta) lo abre el hook colocado `.ProfileModal` cuando el servidor marca
  `data-open="true"`; el cierre (Esc, la X o el backdrop) es nativo y el hook
  lo devuelve al servidor para que `data-open` no quede mintiendo.
  """

  use TokengateWeb, :live_component

  alias Tokengate.Accounts

  @impl true
  def update(assigns, socket) do
    user = assigns.user

    {:ok,
     socket
     |> assign(:user, user)
     |> assign(:initials, assigns.initials)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:saved?, fn -> false end)
     |> assign_new(:form, fn -> password_form(user) end)}
  end

  @impl true
  def handle_event("open_profile", _params, socket) do
    # Abrir siempre limpio: el formulario no arrastra errores de la vez pasada.
    {:noreply,
     socket
     |> assign(:open, true)
     |> assign(:saved?, false)
     |> assign(:form, password_form(socket.assigns.user))}
  end

  # El hook avisa del cierre nativo (Esc, la X o el backdrop).
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("save_password", %{"profile" => params}, socket) do
    user = socket.assigns.user

    case Accounts.update_user_password(user, params) do
      {:ok, user} ->
        Tokengate.Auditing.log(
          user,
          "auth.password_change",
          "user",
          user.id,
          %{"email" => user.email},
          %{origin: "web"}
        )

        {:noreply,
         socket
         |> assign(:user, user)
         |> assign(:saved?, true)
         |> assign(:form, password_form(user))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:saved?, false)
         |> assign(:form, to_form(changeset))}
    end
  end

  attr :user, :map, required: true, doc: "el usuario autenticado"
  attr :initials, :string, required: true, doc: "iniciales para el avatar"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="profile-modal" class="flex items-center">
      <button
        type="button"
        id="profile-avatar-button"
        phx-click="open_profile"
        phx-target={@myself}
        class="avatar avatar-placeholder cursor-pointer rounded-full transition-shadow hover:ring-2 hover:ring-primary/40 focus-visible:ring-2 focus-visible:ring-primary focus-visible:outline-none"
        aria-label={gettext("Open my account")}
        title={gettext("My account")}
      >
        <span class="flex h-9 w-9 items-center justify-center bg-primary text-primary-content rounded-full">
          <span class="text-sm font-semibold">{@initials}</span>
        </span>
      </button>

      <dialog
        id="profile-modal-dialog"
        class="modal"
        data-open={to_string(@open)}
        phx-hook=".ProfileModal"
        phx-target={@myself}
        aria-labelledby="profile-modal-title"
      >
        <div class="modal-box max-h-[90dvh] max-w-lg overflow-y-auto p-0">
          <div class="flex items-start gap-4 px-6 pt-6">
            <span class="avatar avatar-placeholder shrink-0">
              <span class="flex h-12 w-12 items-center justify-center bg-primary text-primary-content rounded-full">
                <span class="text-base font-semibold">{@initials}</span>
              </span>
            </span>

            <div class="min-w-0 flex-1">
              <h3 id="profile-modal-title" class="truncate text-lg font-bold">
                {@user.name}
              </h3>
              <p class="truncate font-mono text-sm text-base-content/60">{@user.email}</p>
              <span class="badge badge-ghost badge-sm mt-1.5">{role_label(@user.global_role)}</span>
            </div>

            <form method="dialog">
              <button class="btn btn-ghost btn-sm btn-circle" aria-label={gettext("Close")}>
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </form>
          </div>

          <div class="space-y-4 px-6 pt-5 pb-6">
            <div :if={@saved?} id="profile-password-saved" class="alert alert-success text-sm">
              <.icon name="hero-check-circle" class="w-4 h-4 shrink-0" />
              <span>{gettext("Password updated.")}</span>
            </div>

            <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
              <dt class="text-xs tracking-wide text-base-content/50 uppercase">{gettext("Name")}</dt>
              <dd class="text-right font-medium">{@user.name}</dd>
              <dt class="text-xs tracking-wide text-base-content/50 uppercase">Email</dt>
              <dd class="truncate text-right font-mono">{@user.email}</dd>
              <dt class="text-xs tracking-wide text-base-content/50 uppercase">{gettext("Role")}</dt>
              <dd class="text-right">{role_label(@user.global_role)}</dd>
            </dl>

            <div class="divider my-0"></div>

            <div>
              <h4 class="font-semibold">{gettext("Change password")}</h4>
              <p class="mt-1 text-xs text-base-content/50">
                {gettext("At least 12 characters, with a letter and a digit.")}
              </p>
            </div>

            <.form
              for={@form}
              id="profile-password-form"
              phx-submit="save_password"
              phx-target={@myself}
              class="space-y-4"
            >
              <.input
                field={@form[:current_password]}
                type="password"
                label={gettext("Current password")}
                required
                autocomplete="current-password"
              />
              <.input
                field={@form[:password]}
                type="password"
                label={gettext("New password")}
                required
                autocomplete="new-password"
              />

              <div class="flex justify-end">
                <button type="submit" class="btn btn-primary btn-sm" id="save-password-btn">
                  {gettext("Save password")}
                </button>
              </div>
            </.form>
          </div>
        </div>

        <form method="dialog" class="modal-backdrop">
          <button>{gettext("Close")}</button>
        </form>
      </dialog>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ProfileModal">
        // El `open` de un <dialog> solo existe del lado del cliente (lo pone
        // showModal), así que cualquier patch del elemento se lo lleva por
        // delante: reponemos el estado que manda el servidor con `data-open`.
        // El cierre nativo (Esc, la X o el backdrop) se devuelve al servidor.
        export default {
          mounted() {
            this.el.addEventListener("close", () => this.pushEventTo(this.el, "close_modal", {}))
            this.syncOpen()
          },
          updated() {
            this.syncOpen()
          },
          syncOpen() {
            const open = this.el.dataset.open === "true"

            if (open && !this.el.open) {
              this.el.showModal()
            } else if (!open && this.el.open) {
              this.el.close()
            }
          }
        }
      </script>
    </div>
    """
  end

  # El formulario usa su propio namespace (`profile[...]`) para no chocar con
  # los ids `user[...]` de las demás páginas (p. ej. /access/users), que
  # comparten shell y por tanto comparten documento.
  defp password_form(user), do: to_form(Accounts.change_user_password(user), as: :profile)

  defp role_label("admin"), do: gettext("Administrator")
  defp role_label("user"), do: gettext("User")
  defp role_label(other), do: String.capitalize(other || "")
end
