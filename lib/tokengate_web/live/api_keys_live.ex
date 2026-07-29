defmodule TokengateWeb.ApiKeysLive do
  @moduledoc """
  Manager/admin view of all API keys grouped by team.

  Regular users see their own keys on /dashboard. This page is for managers
  who need to revoke keys across their teams, and admins who oversee all
  teams. Non-managers are redirected to /dashboard.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    memberships = Accounts.list_team_members_for_user(user.id)
    is_manager = manager?(user, memberships)
    managed_team_members = load_managed_team_members(user, memberships)

    socket =
      socket
      |> assign(:page_title, "API Keys · Tokengate")
      |> assign(:is_manager, is_manager)
      |> assign(:managed_team_members, managed_team_members)

    {:ok, socket}
  end

  defp manager?(%{global_role: "admin"}, _memberships), do: true
  defp manager?(_user, _memberships), do: false

  defp load_managed_team_members(%{global_role: "admin"}, _memberships) do
    Accounts.list_teams()
    |> Enum.map(fn team ->
      {team, Accounts.list_team_members_for_team(team.id)}
    end)
  end

  defp load_managed_team_members(_user, _memberships), do: []

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("revoke_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    # Find the member in any of the managed teams
    member =
      Enum.find_value(socket.assigns.managed_team_members, fn {_team, members} ->
        Enum.find(members, &(&1.id == member_id))
      end)

    cond do
      member == nil ->
        {:noreply, put_flash(socket, :error, "No autorizado.")}

      member.api_key == nil ->
        {:noreply, put_flash(socket, :error, "Esta membresía no tiene clave.")}

      true ->
        case Accounts.revoke_api_key(member.api_key) do
          {:ok, _} ->
            memberships = Accounts.list_team_members_for_user(user.id)

            {:noreply,
             socket
             |> assign(:managed_team_members, load_managed_team_members(user, memberships))
             |> put_flash(:info, "Clave revocada.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
        end
    end
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
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          API Keys
          <:subtitle>Gestión de claves por equipo</:subtitle>
        </.header>

        <%= if not @is_manager do %>
          <div class="alert alert-info" id="not-manager-info">
            <.icon name="hero-information-circle" class="w-5 h-5 shrink-0" />
            <div class="flex-1 text-sm">
              <p>
                Tus claves personales están en el <.link
                  navigate={~p"/dashboard"}
                  class="link link-primary"
                >Dashboard</.link>.
              </p>
            </div>
          </div>
        <% else %>
          <section id="managed-keys-section">
            <%= if @managed_team_members == [] do %>
              <div class="text-center py-12 text-base-content/40">
                <.icon name="hero-key" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                <p>No gestionas ningún equipo.</p>
              </div>
            <% else %>
              <%= for {team, members} <- @managed_team_members do %>
                <div class="card bg-base-100 border border-base-300 shadow-sm mb-4">
                  <div class="card-body">
                    <div class="flex items-center justify-between">
                      <h3 class="font-semibold text-base-content">{team.name}</h3>
                      <span class="text-xs text-base-content/40">
                        {length(members)} miembro(s)
                      </span>
                    </div>
                    <div class="overflow-x-auto">
                      <table class="table table-sm">
                        <thead>
                          <tr>
                            <th>Miembro</th>
                            <th>Clave</th>
                            <th>Estado</th>
                            <th>Creada</th>
                            <th></th>
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
                            <td>
                              {if member.api_key,
                                do: format_date(member.api_key.inserted_at),
                                else: "—"}
                            </td>
                            <td>
                              <%= if member.api_key && member.api_key.status == "active" do %>
                                <button
                                  phx-click="revoke_key"
                                  phx-value-id={member.id}
                                  data-confirm="¿Revocar clave? Esta acción no se puede deshacer."
                                  class="btn btn-xs btn-ghost text-error"
                                  id={"revoke-#{member.id}"}
                                >
                                  <.icon name="hero-no-symbol" class="w-3 h-3" /> Revocar
                                </button>
                              <% end %>
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </section>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end
end
