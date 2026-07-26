defmodule TokengateWeb.ApiKeysLive do
  @moduledoc false
  use TokengateWeb, :live_view

  alias Tokengate.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "API Keys · Tokengate")
      |> assign(:new_token, nil)
      |> assign(:new_token_team, nil)
      |> load_data(user)

    {:ok, socket}
  end

  defp load_data(socket, user) do
    memberships = Accounts.list_team_members_for_user(user.id)
    is_manager = manager?(user, memberships)
    managed_team_members = load_managed_team_members(user, memberships)

    socket
    |> assign(:memberships, memberships)
    |> assign(:is_manager, is_manager)
    |> assign(:managed_team_members, managed_team_members)
  end

  defp manager?(%{global_role: "admin"}, _memberships), do: true

  defp manager?(_user, memberships) do
    Enum.any?(memberships, &(&1.team_role == "manager"))
  end

  defp load_managed_team_members(%{global_role: "admin"}, _memberships) do
    Accounts.list_teams()
    |> Enum.map(fn team ->
      {team, Accounts.list_team_members_for_team(team.id)}
    end)
  end

  defp load_managed_team_members(_user, memberships) do
    managed_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    Enum.map(managed_team_ids, fn team_id ->
      team = Accounts.get_team!(team_id)
      {team, Accounts.list_team_members_for_team(team_id)}
    end)
  end

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("replace_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case Enum.find(socket.assigns[:memberships], &(&1.id == member_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "No autorizado.")}

      member ->
        case Accounts.replace_api_key(member) do
          {:ok, _api_key, new_token} ->
            {:noreply,
             socket
             |> assign(:new_token, new_token)
             |> assign(:new_token_team, member.team.name)
             |> load_data(user)
             |> put_flash(:info, "Clave reemplazada correctamente.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "No se pudo reemplazar la clave.")}
        end
    end
  end

  def handle_event("revoke_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case Enum.find(socket.assigns[:memberships], &(&1.id == member_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "No autorizado.")}

      member ->
        case member.api_key do
          nil ->
            {:noreply, put_flash(socket, :error, "Esta membresía no tiene clave.")}

          api_key ->
            case Accounts.revoke_api_key(api_key) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> load_data(user)
                 |> put_flash(:info, "Clave revocada.")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
            end
        end
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  ## Template helpers ------------------------------------------------------

  defp masked_key(%{api_key: %{key_prefix: prefix}}) when is_binary(prefix) do
    "#{prefix}••••"
  end

  defp masked_key(_), do: "Sin clave"

  defp key_status_badge(%{api_key: %{status: "active"}}), do: "badge-success"
  defp key_status_badge(%{api_key: %{status: "revoked"}}), do: "badge-error"
  defp key_status_badge(_), do: "badge-ghost"

  defp key_status_label(%{api_key: %{status: "active"}}), do: "Activa"
  defp key_status_label(%{api_key: %{status: "revoked"}}), do: "Revocada"
  defp key_status_label(_), do: "Sin clave"

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%d/%m/%Y")
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          API Keys
          <:subtitle>Gestiona tus claves de acceso a la API</:subtitle>
        </.header>

        <%!-- One-time new token alert --%>
        <div :if={@new_token} class="alert alert-warning shadow-lg" id="new-token-alert" role="alert">
          <.icon name="hero-key" class="w-5 h-5 shrink-0" />
          <div class="flex-1">
            <p class="font-semibold">Nueva clave generada para {@new_token_team}</p>
            <code
              class="block mt-2 p-2 bg-base-200 rounded text-sm font-mono break-all select-all"
              id="new-token-value"
            >
              {@new_token}
            </code>
            <p class="text-xs mt-2 text-base-content/70">
              Copia esta clave ahora. No se volverá a mostrar.
            </p>
          </div>
          <button
            phx-click="dismiss_token"
            class="btn btn-sm btn-ghost"
            id="dismiss-token-btn"
            aria-label="Cerrar"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>

        <section>
          <h2 class="text-base font-semibold mb-3">Tus claves</h2>

          <%= if @memberships == [] do %>
            <div class="text-center py-12 text-base-content/40">
              <.icon name="hero-key" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>No perteneces a ningún equipo todavía.</p>
            </div>
          <% else %>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <%= for membership <- @memberships do %>
                <div
                  class="card bg-base-100 border border-base-300 shadow-sm hover:shadow-md transition-shadow"
                  id={"membership-#{membership.id}"}
                >
                  <div class="card-body p-5">
                    <div class="flex items-center justify-between">
                      <div>
                        <h3 class="font-semibold text-base-content">{membership.team.name}</h3>
                        <p class="text-xs text-base-content/50 mt-0.5 capitalize">
                          {membership.team_role}
                        </p>
                      </div>
                      <span class={["badge", "badge-sm", key_status_badge(membership)]}>
                        {key_status_label(membership)}
                      </span>
                    </div>

                    <div class="mt-3">
                      <p class="text-xs text-base-content/50 uppercase tracking-wide">Clave</p>
                      <code class="text-sm font-mono">{masked_key(membership)}</code>
                    </div>

                    <%= if membership.api_key do %>
                      <p class="text-xs text-base-content/40 mt-2">
                        Creada el {format_date(membership.api_key.inserted_at)}
                      </p>

                      <div class="flex gap-2 mt-3">
                        <button
                          phx-click="replace_key"
                          phx-value-id={membership.id}
                          data-confirm="¿Reemplazar clave? La clave anterior dejará de funcionar inmediatamente."
                          class="btn btn-sm btn-primary"
                          id={"replace-#{membership.id}"}
                        >
                          <.icon name="hero-arrow-path" class="w-4 h-4" />
                          Reemplazar
                        </button>

                        <%= if membership.api_key.status == "active" do %>
                          <button
                            phx-click="revoke_key"
                            phx-value-id={membership.id}
                            data-confirm="¿Revocar clave? Esta acción no se puede deshacer."
                            class="btn btn-sm btn-ghost text-error"
                            id={"revoke-#{membership.id}"}
                          >
                            <.icon name="hero-no-symbol" class="w-4 h-4" />
                            Revocar
                          </button>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </section>

        <%= if @is_manager do %>
          <section id="managed-keys-section">
            <h2 class="text-base font-semibold mb-3">Claves de equipos</h2>

            <%= for {team, members} <- @managed_team_members do %>
              <div class="card bg-base-100 border border-base-300 shadow-sm mb-4">
                <div class="card-body">
                  <h3 class="font-semibold text-base-content">{team.name}</h3>
                  <div class="overflow-x-auto">
                    <table class="table table-sm">
                      <thead>
                        <tr>
                          <th>Miembro</th>
                          <th>Clave</th>
                          <th>Estado</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={member <- members} id={"team-key-#{member.id}"}>
                          <td>{member.user.email}</td>
                          <td><code class="text-sm font-mono">{masked_key(member)}</code></td>
                          <td>
                            <span class={["badge", "badge-sm", key_status_badge(member)]}>
                              {key_status_label(member)}
                            </span>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            <% end %>
          </section>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end
end
