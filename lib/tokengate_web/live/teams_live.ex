defmodule TokengateWeb.TeamsLive do
  @moduledoc """
  Admin-only CRUD for teams + per-team model alias grants.

  Only admins (global_role == "admin") can access this page. Non-admins
  are redirected to /dashboard with an error flash.

  Teams carry default budgets and limits applied to all members. Model
  aliases can be granted per-team via the team_model_aliases join table.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Accounts.Team
  alias Tokengate.Providers
  alias Tokengate.Providers.{ModelAlias, TeamModelAlias}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user.global_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, "No tienes permisos para acceder a esta sección.")
       |> redirect(to: "/dashboard")}
    else
      socket =
        socket
        |> assign(:page_title, "Equipos · Tokengate")
        |> assign(:form, nil)
        |> assign(:editing_team_id, nil)
        |> load_teams()

      {:ok, socket}
    end
  end

  ## Data loading ---------------------------------------------------------

  defp load_teams(socket) do
    teams =
      from(t in Team,
        preload: [:team_members],
        order_by: [asc: t.name]
      )
      |> Repo.all()

    granted_aliases =
      from(tma in TeamModelAlias, select: {tma.team_id, tma.model_alias_id})
      |> Repo.all()
      |> Enum.group_by(fn {team_id, _} -> team_id end, fn {_, alias_id} -> alias_id end)

    aliases_by_org =
      from(ma in ModelAlias, order_by: [asc: ma.name])
      |> Repo.all()
      |> Enum.group_by(fn _ma -> "all" end)

    socket
    |> stream(:teams, teams, reset: true)
    |> assign(:teams_empty?, teams == [])
    |> assign(:granted_aliases, granted_aliases)
    |> assign(:aliases_by_org, aliases_by_org)
  end

  ## Events — team CRUD ---------------------------------------------------

  @impl true
  def handle_event("new_team", _params, socket) do
    changeset = Accounts.change_team(%Team{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :team))
     |> assign(:editing_team_id, :new)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_team_id, nil)}
  end

  def handle_event("edit_team", %{"id" => team_id}, socket) do
    team = Accounts.get_team!(team_id)
    changeset = Accounts.change_team(team)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :team))
     |> assign(:editing_team_id, team.id)}
  end

  def handle_event("save_team", %{"team" => team_params}, socket) do
    save_team(socket, socket.assigns.editing_team_id, team_params)
  end

  def handle_event("delete_team", %{"id" => team_id}, socket) do
    team = Accounts.get_team!(team_id)

    case Accounts.delete_team(team) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Equipo eliminado.")
         |> load_teams()}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field} #{message}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, "No se pudo eliminar: #{msg}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el equipo.")}
    end
  end

  ## Events — alias grants ------------------------------------------------

  def handle_event("toggle_alias", %{"team-id" => team_id, "alias-id" => alias_id}, socket) do
    team_alias_ids = Map.get(socket.assigns.granted_aliases, team_id, [])

    result =
      if alias_id in team_alias_ids do
        Providers.revoke_alias_from_team(team_id, alias_id)
      else
        Providers.grant_alias_to_team(team_id, alias_id)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Aliases actualizados.")
         |> load_teams()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar el alias.")}
    end
  end

  ## Private helpers — save ----------------------------------------------

  defp save_team(socket, :new, team_params) do
    case Accounts.create_team(team_params) do
      {:ok, _team} ->
        {:noreply,
         socket
         |> put_flash(:info, "Equipo creado.")
         |> assign(:form, nil)
         |> assign(:editing_team_id, nil)
         |> load_teams()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :team))}
    end
  end

  defp save_team(socket, team_id, team_params) when is_binary(team_id) do
    team = Accounts.get_team!(team_id)

    case Accounts.update_team(team, team_params) do
      {:ok, _team} ->
        {:noreply,
         socket
         |> put_flash(:info, "Equipo actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_team_id, nil)
         |> load_teams()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :team))}
    end
  end

  ## Template helpers -----------------------------------------------------

  def granted_alias_ids(granted_aliases, team_id) do
    Map.get(granted_aliases, team_id, [])
  end

  def format_decimal(%Decimal{} = d), do: Decimal.to_string(d)
  def format_decimal(nil), do: "—"
  def format_decimal(value), do: to_string(value)

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          Equipos
          <:subtitle>Gestiona equipos, presupuestos y aliases de modelos</:subtitle>
          <:actions>
            <.button phx-click="new_team" id="new-team-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo equipo
            </.button>
          </:actions>
        </.header>

        <div :if={@form} class="card bg-base-100 border border-base-300 shadow-sm" id="team-form-card">
          <div class="card-body">
            <h2 class="text-base font-semibold mb-2">
              {if @editing_team_id == :new, do: "Nuevo equipo", else: "Editar equipo"}
            </h2>
            <.form for={@form} id="team-form" phx-submit="save_team">
              <.input
                field={@form[:name]}
                type="text"
                label="Nombre"
                hint="Nombre identificativo del equipo."
              />
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <.input
                  field={@form[:default_daily_budget_usd]}
                  type="number"
                  label="Presupuesto diario (USD)"
                  step="any"
                  hint="Presupuesto diario por miembro. Cada miembro puede tener un extra que se suma a este valor. Vacío = sin límite."
                />
                <.input
                  field={@form[:default_monthly_budget_usd]}
                  type="number"
                  label="Presupuesto mensual (USD)"
                  step="any"
                  hint="Presupuesto mensual por miembro. Vacío = sin límite."
                />
                <.input
                  field={@form[:default_concurrency_limit]}
                  type="number"
                  label="Concurrencia"
                  hint="Concurrencia por miembro. Cada miembro puede tener un extra que se suma a este valor."
                />
                <.input
                  field={@form[:default_rpm_limit]}
                  type="number"
                  label="RPM"
                  hint="Requests por minuto por miembro."
                />
              </div>
              <div class="flex gap-2 mt-3">
                <button type="submit" class="btn btn-primary" id="save-team-btn">Guardar</button>
                <button type="button" phx-click="cancel_form" class="btn btn-ghost">
                  Cancelar
                </button>
              </div>
            </.form>
          </div>
        </div>

        <div id="teams" phx-update="stream">
          <div :if={@teams_empty?} class="text-center py-12 text-base-content/40" id="teams-empty">
            <.icon name="hero-user-group" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>No hay equipos todavía.</p>
          </div>
          <div
            :for={{id, team} <- @streams.teams}
            id={id}
            class="card bg-base-100 border border-base-300 shadow-sm mb-4"
          >
            <div class="card-body">
              <div class="flex items-start justify-between">
                <div>
                  <h3 class="font-semibold text-base-content">{team.name}</h3>
                  <p class="text-xs text-base-content/50 mt-0.5">
                    {length(team.team_members)} miembros
                  </p>
                </div>
                <div class="flex gap-2">
                  <.link
                    navigate={~p"/dashboard/teams/#{team}/members"}
                    class="btn btn-sm btn-ghost"
                    id={"members-link-#{team.id}"}
                  >
                    Miembros
                  </.link>
                  <button
                    phx-click="edit_team"
                    phx-value-id={team.id}
                    class="btn btn-sm btn-ghost"
                    id={"edit-#{team.id}"}
                  >
                    Editar
                  </button>
                  <button
                    phx-click="delete_team"
                    phx-value-id={team.id}
                    class="btn btn-sm btn-ghost text-error"
                    id={"delete-#{team.id}"}
                    data-confirm="¿Eliminar equipo? Esta acción no se puede deshacer."
                  >
                    Eliminar
                  </button>
                </div>
              </div>

              <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mt-3 text-sm">
                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide">Diario</p>
                  <p class="font-medium">{format_decimal(team.default_daily_budget_usd)}</p>
                </div>
                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide">Mensual</p>
                  <p class="font-medium">{format_decimal(team.default_monthly_budget_usd)}</p>
                </div>
                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide">Concurrencia</p>
                  <p class="font-medium">{team.default_concurrency_limit}</p>
                </div>
                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide">RPM</p>
                  <p class="font-medium">{team.default_rpm_limit}</p>
                </div>
              </div>

              <div class="mt-4 pt-4 border-t border-base-300">
                <h4 class="text-sm font-semibold mb-2">Aliases de modelos</h4>
                <div class="flex flex-wrap gap-3" id={"aliases-#{team.id}"}>
                  <label
                    :for={alias <- Map.get(@aliases_by_org, "all", [])}
                    class="flex items-center gap-2 cursor-pointer text-sm"
                  >
                    <input
                      type="checkbox"
                      phx-click="toggle_alias"
                      phx-value-team-id={team.id}
                      phx-value-alias-id={alias.id}
                      checked={alias.id in granted_alias_ids(@granted_aliases, team.id)}
                      class="checkbox checkbox-sm"
                      id={"alias-#{team.id}-#{alias.id}"}
                    />
                    <span>{alias.name}</span>
                  </label>
                  <p
                    :if={Map.get(@aliases_by_org, "all", []) == []}
                    class="text-xs text-base-content/40"
                  >
                    No hay aliases disponibles para esta organización.
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
