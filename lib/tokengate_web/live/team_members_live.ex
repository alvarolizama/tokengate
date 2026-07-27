defmodule TokengateWeb.TeamMembersLive do
  @moduledoc """
  Per-team member management.

  Access:
    - admin: manages members of any team.
    - manager: manages members of teams where they have team_role == "manager".
    - user: denied — redirected to /dashboard.

  Supports:
    - Add member by email (creates team_member + auto-generates API key).
    - Remove member.
    - Per-member extras: extra_daily_budget_usd, extra_concurrency, extra_rpm,
      extra_model_aliases (individual grants beyond team aliases).
    - Change team_role (manager/user).
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Providers
  alias Tokengate.Providers.{ModelAlias, TeamMemberExtraAlias}
  alias Tokengate.Repo

  @impl true
  def mount(%{"id" => team_id}, _session, socket) do
    user = socket.assigns[:current_user]
    team = Accounts.get_team!(team_id)

    case check_access(user, team) do
      :ok ->
        socket =
          socket
          |> assign(:page_title, "Miembros · Tokengate")
          |> assign(:team, team)
          |> assign(:editing_member_id, nil)
          |> assign(:add_member_error, nil)
          |> assign(:member_form, to_form(%{"email" => "", "team_role" => "user"}))
          |> load_data()

        {:ok, socket}

      {:denied, msg} ->
        {:ok,
         socket
         |> put_flash(:error, msg)
         |> redirect(to: "/dashboard")}
    end
  end

  ## Access control -------------------------------------------------------

  defp check_access(%{global_role: "admin"}, _team), do: :ok

  defp check_access(%{global_role: "user"} = user, team) do
    memberships = Accounts.list_team_members_for_user(user.id)

    if Enum.any?(memberships, &(&1.team_id == team.id and &1.team_role == "manager")) do
      :ok
    else
      {:denied, "No tienes permisos para gestionar este equipo."}
    end
  end

  ## Data loading ---------------------------------------------------------

  defp load_data(socket) do
    team = socket.assigns.team
    members = Accounts.list_team_members_for_team(team.id)

    # Get all available model aliases
    org_alias_ids =
      from(ma in ModelAlias,
        order_by: [asc: ma.name]
      )
      |> Repo.all()

    # Preload extra alias ids per member
    extra_aliases =
      from(tmea in TeamMemberExtraAlias,
        where: tmea.team_member_id in ^Enum.map(members, & &1.id),
        select: {tmea.team_member_id, tmea.model_alias_id}
      )
      |> Repo.all()
      |> Enum.group_by(fn {tm_id, _} -> tm_id end, fn {_, alias_id} -> alias_id end)

    socket
    |> assign(:members, members)
    |> assign(:members_empty?, members == [])
    |> assign(:org_aliases, org_alias_ids)
    |> assign(:extra_aliases, extra_aliases)
  end

  ## Events — add member --------------------------------------------------

  @impl true
  def handle_event("validate_add_member", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("add_member", %{"email" => email, "team_role" => team_role}, socket) do
    team = socket.assigns.team

    case Accounts.get_user_by_email(email) do
      nil ->
        {:noreply,
         socket
         |> assign(:add_member_error, "No existe un usuario con ese email.")
         |> assign(:member_form, to_form(%{"email" => email, "team_role" => team_role}))}

      user ->
        case Accounts.create_team_member(%{
               user_id: user.id,
               team_id: team.id,
               team_role: team_role
             }) do
          {:ok, _member} ->
            {:noreply,
             socket
             |> put_flash(:info, "Miembro añadido. Genera su API key desde la sección API Keys.")
             |> assign(:add_member_error, nil)
             |> assign(:member_form, to_form(%{"email" => "", "team_role" => "user"}))
             |> load_data()}

          {:error, changeset} ->
            msg = format_changeset_errors(changeset)
            {:noreply, assign(socket, :add_member_error, msg)}
        end
    end
  end

  ## Events — remove member ----------------------------------------------

  def handle_event("remove_member", %{"id" => member_id}, socket) do
    member = Accounts.get_team_member!(member_id)

    # Verify the member belongs to this team
    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
      case Accounts.delete_team_member(member) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Miembro eliminado.")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo eliminar el miembro.")}
      end
    end
  end

  ## Events — change role ------------------------------------------------

  def handle_event("change_role", %{"id" => member_id, "team_role" => team_role}, socket) do
    member = Accounts.get_team_member!(member_id)

    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
      case Accounts.update_team_member(member, %{team_role: team_role}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Rol actualizado.")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo actualizar el rol.")}
      end
    end
  end

  ## Events — override edits ---------------------------------------------

  def handle_event("edit_overrides", %{"id" => member_id}, socket) do
    {:noreply, assign(socket, :editing_member_id, member_id)}
  end

  def handle_event("cancel_overrides", _params, socket) do
    {:noreply, assign(socket, :editing_member_id, nil)}
  end

  def handle_event("save_overrides", %{"overrides" => override_params} = params, socket) do
    member_id = params["id"]
    member = Accounts.get_team_member!(member_id)

    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
      attrs =
        %{
          extra_daily_budget_usd: parse_decimal(override_params["extra_daily_budget_usd"]),
          extra_concurrency: parse_integer(override_params["extra_concurrency"]),
          extra_rpm: parse_integer(override_params["extra_rpm"])
        }

      case Accounts.update_team_member(member, attrs) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Extras actualizados.")
           |> assign(:editing_member_id, nil)
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudieron actualizar los extras.")}
      end
    end
  end

  ## Events — extra alias grants -----------------------------------------

  def handle_event(
        "toggle_extra_alias",
        %{"member-id" => member_id, "alias-id" => alias_id},
        socket
      ) do
    member = Accounts.get_team_member!(member_id)

    cond do
      member.team_id != socket.assigns.team.id ->
        {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}

      true ->
        existing = Map.get(socket.assigns.extra_aliases, member_id, [])

        result =
          if alias_id in existing do
            Providers.revoke_extra_alias(member_id, alias_id)
          else
            Providers.grant_extra_alias(member_id, alias_id)
          end

        case result do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Aliases actualizados.")
             |> load_data()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo actualizar el alias.")}
        end
    end
  end

  ## Helpers --------------------------------------------------------------

  defp parse_decimal(""), do: nil
  defp parse_decimal(nil), do: nil
  defp parse_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp parse_decimal(%Decimal{} = d), do: d

  defp parse_integer(""), do: nil
  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_binary(value), do: String.to_integer(value)
  defp parse_integer(value) when is_integer(value), do: value

  defp format_changeset_errors(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
      |> Enum.flat_map(fn {field, msgs} ->
        Enum.map(msgs, fn msg -> "#{field}: #{msg}" end)
      end)

    Enum.join(errors, ", ")
  end

  defp extra_alias_ids(extra_aliases, member_id) do
    Map.get(extra_aliases, member_id, [])
  end

  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_decimal(nil), do: "—"
  defp format_decimal(value), do: to_string(value)

  defp role_badge("manager"), do: {"badge-primary", "Manager"}
  defp role_badge("user"), do: {"badge-ghost", "Usuario"}
  defp role_badge(_), do: {"badge-ghost", "—"}

  defp masked_key(%{api_key: %{key_prefix: prefix}}) when is_binary(prefix), do: "#{prefix}••••"
  defp masked_key(_), do: "Sin clave"

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          Miembros de {@team.name}
          <:subtitle>Añade miembros, gestiona roles y extras</:subtitle>
          <:actions>
            <.link navigate={~p"/dashboard/teams"} class="btn btn-ghost" id="back-to-teams">
              <.icon name="hero-arrow-left" class="w-4 h-4" /> Volver
            </.link>
          </:actions>
        </.header>

        <div class="card bg-base-100 border border-base-300 shadow-sm" id="add-member-card">
          <div class="card-body">
            <h2 class="text-base font-semibold mb-2">Añadir miembro</h2>
            <.form for={@member_form} id="add-member-form" phx-submit="add_member">
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 items-end">
                <.input
                  field={@member_form[:email]}
                  type="email"
                  label="Email del usuario"
                  placeholder="usuario@ejemplo.com"
                />
                <.input
                  field={@member_form[:team_role]}
                  type="select"
                  label="Rol"
                  options={[{"Usuario", "user"}, {"Manager", "manager"}]}
                />
                <div>
                  <button type="submit" class="btn btn-primary w-full" id="add-member-btn">Añadir</button>
                </div>
              </div>
            </.form>
            <p :if={@add_member_error} class="text-sm text-error mt-2" id="add-member-error">
              <.icon name="hero-exclamation-circle" class="w-4 h-4 inline mr-1" />
              {@add_member_error}
            </p>
          </div>
        </div>

        <div id="members">
          <div :if={@members_empty?} class="text-center py-12 text-base-content/40" id="members-empty">
            <.icon name="hero-users" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>Este equipo no tiene miembros todavía.</p>
          </div>
          <div
            :for={member <- @members}
            id={"members-#{member.id}"}
            class="card bg-base-100 border border-base-300 shadow-sm mb-4"
          >
            <div class="card-body">
              <div class="flex items-start justify-between">
                <div>
                  <h3 class="font-semibold text-base-content">{member.user.email}</h3>
                  <p class="text-xs text-base-content/50 mt-0.5">
                    {member.user.name} · Clave: <code class="font-mono">{masked_key(member)}</code>
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <span class={["badge", "badge-sm", elem(role_badge(member.team_role), 0)]}>
                    {elem(role_badge(member.team_role), 1)}
                  </span>
                </div>
              </div>

              <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mt-3 text-sm">
                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide">Extra diario</p>
                  <p class="font-medium">{format_decimal(member.extra_daily_budget_usd)}</p>
                </div>
                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide">
                    Extra concurrencia
                  </p>
                  <p class="font-medium">{member.extra_concurrency || "—"}</p>
                </div>
                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide">Extra RPM</p>
                  <p class="font-medium">{member.extra_rpm || "—"}</p>
                </div>
                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide">Estado</p>
                  <p class="font-medium capitalize">{member.status}</p>
                </div>
              </div>

              <div class="flex flex-wrap gap-2 mt-3">
                <div class="flex items-center gap-1">
                  <span class="text-xs text-base-content/50 mr-1">Rol:</span>
                  <form
                    phx-change="change_role"
                    phx-value-id={member.id}
                    id={"role-form-#{member.id}"}
                  >
                    <select
                      name="team_role"
                      class="select select-bordered select-sm"
                      id={"role-select-#{member.id}"}
                    >
                      <option value="user" selected={member.team_role == "user"}>Usuario</option>
                      <option value="manager" selected={member.team_role == "manager"}>
                        Manager
                      </option>
                    </select>
                  </form>
                </div>

                <button
                  phx-click="edit_overrides"
                  phx-value-id={member.id}
                  class="btn btn-sm btn-ghost"
                  id={"edit-overrides-#{member.id}"}
                >
                  Extras
                </button>

                <button
                  phx-click="remove_member"
                  phx-value-id={member.id}
                  class="btn btn-sm btn-ghost text-error"
                  id={"remove-#{member.id}"}
                  data-confirm="¿Eliminar miembro del equipo?"
                >
                  Eliminar
                </button>
              </div>

              <%= if @editing_member_id == member.id do %>
                <div class="mt-3 pt-3 border-t border-base-300" id={"overrides-form-#{member.id}"}>
                  <h4 class="text-sm font-semibold mb-2">Extras del miembro</h4>
                  <.form
                    for={
                      to_form(%{
                        "extra_daily_budget_usd" =>
                          if(member.extra_daily_budget_usd,
                            do: Decimal.to_string(member.extra_daily_budget_usd),
                            else: ""
                          ),
                        "extra_concurrency" =>
                          if(member.extra_concurrency,
                            do: to_string(member.extra_concurrency),
                            else: ""
                          ),
                        "extra_rpm" =>
                          if(member.extra_rpm,
                            do: to_string(member.extra_rpm),
                            else: ""
                          )
                      })
                    }
                    id={"override-form-#{member.id}"}
                    phx-submit="save_overrides"
                    phx-value-id={member.id}
                  >
                    <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                      <.input
                        field={to_form(%{})[:extra_daily_budget_usd]}
                        type="number"
                        label="Extra presupuesto diario (USD)"
                        step="any"
                        name="overrides[extra_daily_budget_usd]"
                        value={
                          if(member.extra_daily_budget_usd,
                            do: Decimal.to_string(member.extra_daily_budget_usd),
                            else: ""
                          )
                        }
                      />
                      <.input
                        field={to_form(%{})[:extra_concurrency]}
                        type="number"
                        label="Extra concurrencia"
                        name="overrides[extra_concurrency]"
                        value={
                          if(member.extra_concurrency,
                            do: to_string(member.extra_concurrency),
                            else: ""
                          )
                        }
                      />
                      <.input
                        field={to_form(%{})[:extra_rpm]}
                        type="number"
                        label="Extra RPM"
                        name="overrides[extra_rpm]"
                        value={
                          if(member.extra_rpm,
                            do: to_string(member.extra_rpm),
                            else: ""
                          )
                        }
                      />
                    </div>
                    <div class="flex gap-2 mt-2">
                      <button type="submit" class="btn btn-primary" id={"save-overrides-#{member.id}"}>Guardar</button>
                      <button type="button" phx-click="cancel_overrides" class="btn btn-ghost">
                        Cancelar
                      </button>
                    </div>
                  </.form>
                </div>
              <% end %>

              <div class="mt-3 pt-3 border-t border-base-300">
                <h4 class="text-sm font-semibold mb-2">Aliases extra</h4>
                <div class="flex flex-wrap gap-3">
                  <label
                    :for={alias <- @org_aliases}
                    class="flex items-center gap-2 cursor-pointer text-sm"
                  >
                    <input
                      type="checkbox"
                      phx-click="toggle_extra_alias"
                      phx-value-member-id={member.id}
                      phx-value-alias-id={alias.id}
                      checked={alias.id in extra_alias_ids(@extra_aliases, member.id)}
                      class="checkbox checkbox-sm"
                      id={"extra-alias-#{member.id}-#{alias.id}"}
                    />
                    <span>{alias.name}</span>
                  </label>
                  <p :if={@org_aliases == []} class="text-xs text-base-content/40">
                    No hay aliases disponibles.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
