defmodule TokengateWeb.TeamsLive do
  @moduledoc """
  Admin-only CRUD for teams + per-team model alias grants + observability webhooks.

  Only admins (global_role == "admin") can access this page. Non-admins
  are redirected to /dashboard with an error flash.

  Teams carry default budgets and limits applied to all members. Model
  aliases can be granted per-team via the team_model_aliases join table.
  Observability destinations (webhooks) are managed per-team.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Accounts.Team
  alias Tokengate.Budgets
  alias Tokengate.Observability
  alias Tokengate.Observability.Destination
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
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:form, nil)
        |> assign(:editing_team_id, nil)
        |> assign(:webhook_form, nil)
        |> assign(:editing_webhook_team_id, nil)
        |> assign(:editing_webhook_id, nil)
        |> assign(:team_search, "")
        |> load_teams()

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

  defp load_teams(socket) do
    search = socket.assigns[:team_search] || ""

    teams =
      from(t in Team,
        preload: [:team_members],
        order_by: [asc: t.name]
      )
      |> Repo.all()
      |> then(fn teams ->
        if search == "" do
          teams
        else
          search_down = String.downcase(search)

          Enum.filter(teams, fn t ->
            String.contains?(String.downcase(t.name), search_down)
          end)
        end
      end)

    granted_aliases =
      from(tma in TeamModelAlias, select: {tma.team_id, tma.model_alias_id})
      |> Repo.all()
      |> Enum.group_by(fn {team_id, _} -> team_id end, fn {_, alias_id} -> alias_id end)

    aliases_by_org =
      from(ma in ModelAlias, order_by: [asc: ma.name])
      |> Repo.all()
      |> Enum.group_by(fn _ma -> "all" end)

    # Single query for all teams' destinations (avoids one query per team)
    destinations_by_team =
      Observability.list_destinations_for_teams(Enum.map(teams, & &1.id))

    # Budget + spend rollup per team and per member
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    member_budgets = Budgets.list_member_budgets(timezone)

    # Usage tiers per team (last 30 days)
    usage_tiers_by_team =
      teams
      |> Enum.map(& &1.id)
      |> Map.new(fn team_id ->
        tiers = Tokengate.Metrics.Rollup.member_usage_tiers(team_id, from: days_ago(30))
        {team_id, tiers}
      end)

    team_budgets =
      member_budgets
      |> Enum.group_by(fn mb -> mb.member.team_id end)
      |> Map.new(fn {team_id, budgets} ->
        team = Enum.find(teams, &(&1.id == team_id))

        monthly_limit_usd =
          budgets
          |> Enum.map(& &1.monthly_limit_usd)
          |> Enum.reject(&is_nil/1)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

        monthly_spend_usd =
          Enum.reduce(budgets, Decimal.new(0), &Decimal.add(&1.monthly_spend_usd, &2))

        estimated_monthly_usd =
          if team && team.monthly_budget_per_user_usd do
            team.monthly_budget_per_user_usd
            |> Decimal.mult(Decimal.new(length(budgets)))
          else
            nil
          end

        estimated_monthly_extra_usd =
          Enum.reduce(budgets, Decimal.new(0), fn mb, acc ->
            if mb.member.extra_monthly_budget_usd,
              do: Decimal.add(acc, mb.member.extra_monthly_budget_usd),
              else: acc
          end)

        {team_id,
         %{
           monthly_limit_usd: monthly_limit_usd,
           monthly_spend_usd: monthly_spend_usd,
           estimated_monthly_usd: estimated_monthly_usd,
           estimated_monthly_extra_usd: estimated_monthly_extra_usd,
           member_count: length(budgets),
           member_budgets: budgets
         }}
      end)

    socket
    |> stream(:teams, teams, reset: true)
    |> assign(:teams_empty?, teams == [])
    |> assign(:granted_aliases, granted_aliases)
    |> assign(:aliases_by_org, aliases_by_org)
    |> assign(:destinations_by_team, destinations_by_team)
    |> assign(:team_budgets, team_budgets)
    |> assign(:usage_tiers_by_team, usage_tiers_by_team)
  end

  defp days_ago(n) do
    DateTime.add(DateTime.utc_now(), -n * 86400, :second)
  end

  ## Events — team CRUD ---------------------------------------------------

  @impl true
  def handle_event("search_teams", %{"team_search" => search}, socket) do
    {:noreply, socket |> assign(:team_search, search) |> load_teams()}
  end

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

  ## Events — webhook CRUD -----------------------------------------------

  def handle_event("new_webhook", params, socket) do
    team_id = params["team-id"] || params["team_id"]
    changeset = Observability.change_destination(%Destination{})

    {:noreply,
     socket
     |> assign(:webhook_form, to_form(changeset, as: :destination))
     |> assign(:editing_webhook_team_id, team_id)
     |> assign(:editing_webhook_id, :new)
     |> load_teams()}
  end

  def handle_event("edit_webhook", params, socket) do
    team_id = params["team-id"] || params["team_id"]
    webhook_id = params["webhook-id"] || params["webhook_id"]
    destination = Observability.get_destination!(webhook_id)
    changeset = Observability.change_destination(destination)

    {:noreply,
     socket
     |> assign(:webhook_form, to_form(changeset, as: :destination))
     |> assign(:editing_webhook_team_id, team_id)
     |> assign(:editing_webhook_id, webhook_id)
     |> load_teams()}
  end

  def handle_event("cancel_webhook", _params, socket) do
    {:noreply,
     socket
     |> assign(:webhook_form, nil)
     |> assign(:editing_webhook_team_id, nil)
     |> assign(:editing_webhook_id, nil)
     |> load_teams()}
  end

  def handle_event("save_webhook", %{"destination" => destination_params}, socket) do
    team_id = socket.assigns.editing_webhook_team_id
    editing_id = socket.assigns.editing_webhook_id

    # Parse headers from JSON string if present
    destination_params =
      Map.update(destination_params, "headers", %{}, fn
        headers when is_map(headers) ->
          headers

        headers when is_binary(headers) and headers != "" ->
          case Jason.decode(headers) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{"_raw" => headers}
          end

        _ ->
          %{}
      end)

    destination_params = Map.put(destination_params, "team_id", team_id)

    result =
      if editing_id == :new do
        Observability.create_destination(destination_params)
      else
        destination = Observability.get_destination!(editing_id)
        Observability.update_destination(destination, destination_params)
      end

    case result do
      {:ok, _destination} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook guardado.")
         |> assign(:webhook_form, nil)
         |> assign(:editing_webhook_team_id, nil)
         |> assign(:editing_webhook_id, nil)
         |> load_teams()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :webhook_form, to_form(changeset, as: :destination))}
    end
  end

  def handle_event("delete_webhook", params, socket) do
    webhook_id = params["webhook-id"] || params["webhook_id"]
    destination = Observability.get_destination!(webhook_id)

    case Observability.delete_destination(destination) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook eliminado.")
         |> load_teams()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el webhook.")}
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

  def get_member_tier(usage_tiers_by_team, team_id, member_id) do
    tiers = Map.get(usage_tiers_by_team, team_id, [])
    Enum.find(tiers, &(&1.team_member_id == member_id))
  end

  def tier_badge_class("alto"), do: "badge-error"
  def tier_badge_class("regular"), do: "badge-warning"
  def tier_badge_class("bajo"), do: "badge-ghost"
  def tier_badge_class(_), do: "badge-ghost"

  def format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  def format_decimal(nil), do: "—"
  def format_decimal(value), do: to_string(value)

  # The `headers` destination field is a :map column, but the form edits it as
  # a JSON string in a textarea. Convert the map to JSON for display; empty
  # maps render as an empty textarea. Invalid JSON submitted previously is
  # stored as %{"_raw" => original} — show the original string back.
  def headers_to_string(%{} = headers) when map_size(headers) == 0, do: ""

  def headers_to_string(%{} = headers) do
    case Map.get(headers, "_raw") do
      nil -> Jason.encode!(headers, pretty: true)
      raw -> raw
    end
  end

  def headers_to_string(_), do: ""

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Equipos
          <:subtitle>Gestiona equipos, presupuestos, aliases de modelos y webhooks</:subtitle>
          <:actions>
            <div class="flex items-center gap-2">
              <input
                type="text"
                name="team_search"
                value={@team_search}
                placeholder="Buscar equipo…"
                phx-change="search_teams"
                phx-debounce="200"
                class="input input-sm w-48"
              />
              <.button phx-click="new_team" id="new-team-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> Nuevo equipo
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- Team form (create / edit) — modal --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
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
                    field={@form[:monthly_budget_per_user_usd]}
                    type="number"
                    label="Budget mensual por usuario (USD)"
                    step="any"
                    hint="Presupuesto mensual individual para cada miembro. Vacío = sin límite."
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
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-team-btn">Guardar</button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Webhook form (create / edit) — modal --%>
        <div
          :if={@webhook_form}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id={"webhook-form-#{@editing_webhook_team_id}"}
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_webhook" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_webhook_id == :new, do: "Nuevo webhook", else: "Editar webhook"}
              </h2>
              <.form
                for={@webhook_form}
                id={"destination-form-#{@editing_webhook_team_id}"}
                phx-submit="save_webhook"
              >
                <.input
                  field={@webhook_form[:name]}
                  type="text"
                  label="Nombre"
                  hint="Nombre identificativo del webhook. Ej.: «Datadog - Producción»."
                />
                <.input
                  field={@webhook_form[:url]}
                  type="text"
                  label="URL"
                  hint="Endpoint HTTPS donde se enviarán los datos de telemetría (formato OTLP)."
                />
                <.input
                  field={@webhook_form[:headers]}
                  value={headers_to_string(@webhook_form[:headers].value)}
                  type="textarea"
                  label="Cabeceras (JSON)"
                  placeholder='{"Authorization": "Bearer xxx"}'
                  hint="Cabeceras HTTP adicionales en formato JSON. Dejalo vacio si no necesitas cabeceras extra."
                />
                <div class="flex gap-2 mt-4 justify-end">
                  <button
                    type="button"
                    phx-click="cancel_webhook"
                    class="btn btn-ghost btn-sm"
                    id={"cancel-webhook-#{@editing_webhook_team_id}"}
                  >
                    Cancelar
                  </button>
                  <button
                    type="submit"
                    class="btn btn-primary btn-sm"
                    id={"save-webhook-#{@editing_webhook_team_id}"}
                  >
                    Guardar
                  </button>
                </div>
              </.form>
            </div>
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
            class="card bg-base-100 border border-base-300 shadow-sm mb-4 transition-shadow hover:shadow-md"
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

              <% tb =
                Map.get(@team_budgets, team.id, %{
                  monthly_limit_usd: Decimal.new(0),
                  monthly_spend_usd: Decimal.new(0),
                  estimated_monthly_usd: nil,
                  estimated_monthly_extra_usd: Decimal.new(0),
                  member_count: 0,
                  member_budgets: []
                }) %>

              <%!-- Stats cards: configuración + gasto — 5 tarjetas --%>
              <div class="mt-3 grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
                <%!-- Budget mensual/usuario --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Budget/mes
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-primary/10">
                        <.icon name="hero-banknotes" class="w-4 h-4 text-primary" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      ${format_decimal(team.monthly_budget_per_user_usd)}
                    </p>
                    <p class="text-xs text-base-content/40">por usuario</p>
                  </div>
                </div>

                <%!-- Concurrencia/usuario --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Concurrencia
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-accent/10">
                        <.icon name="hero-arrows-right-left" class="w-4 h-4 text-accent" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {team.default_concurrency_limit}
                    </p>
                    <p class="text-xs text-base-content/40">por usuario</p>
                  </div>
                </div>

                <%!-- RPM/usuario --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        RPM
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-accent/10">
                        <.icon name="hero-bolt" class="w-4 h-4 text-accent" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {team.default_rpm_limit}
                    </p>
                    <p class="text-xs text-base-content/40">por usuario</p>
                  </div>
                </div>

                <%!-- Gasto mensual --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Gasto/mes
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-success/10">
                        <.icon name="hero-currency-dollar" class="w-4 h-4 text-success" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      ${format_decimal(tb.monthly_spend_usd)}
                    </p>
                    <p class="text-xs text-base-content/40">real</p>
                  </div>
                </div>

                <%!-- Estimado mensual --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Estimado/mes
                      </span>
                      <span class={[
                        "flex items-center justify-center w-8 h-8 rounded-lg",
                        if(
                          tb.estimated_monthly_extra_usd &&
                            Decimal.compare(tb.estimated_monthly_extra_usd, 0) == :gt,
                          do: "bg-success/10",
                          else: "bg-primary/10"
                        )
                      ]}>
                        <.icon
                          name="hero-calculator"
                          class={[
                            "w-4 h-4",
                            if(
                              tb.estimated_monthly_extra_usd &&
                                Decimal.compare(tb.estimated_monthly_extra_usd, 0) == :gt,
                              do: "text-success",
                              else: "text-primary"
                            )
                          ]}
                        />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      ${format_decimal(
                        Decimal.add(
                          tb.estimated_monthly_usd || Decimal.new(0),
                          tb.estimated_monthly_extra_usd
                        )
                      )}
                    </p>
                    <%= if Decimal.compare(tb.estimated_monthly_extra_usd, 0) == :gt do %>
                      <p class="text-xs text-success">
                        ${format_decimal(tb.estimated_monthly_usd)} base + ${format_decimal(
                          tb.estimated_monthly_extra_usd
                        )} extra
                      </p>
                    <% else %>
                      <p class="text-xs text-base-content/40">proyección</p>
                    <% end %>
                  </div>
                </div>
              </div>

              <div :if={tb.member_budgets != []} class="mt-4 pt-4 border-t border-base-300">
                <h4 class="text-sm font-semibold mb-2">Consumo por miembro</h4>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Usuario</th>
                        <th class="text-center">Tier</th>
                        <th class="text-right">Concurrencia</th>
                        <th class="text-right">RPM</th>
                        <th class="text-right">Gasto/mes</th>
                        <th class="text-right">Budget/mes</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={mb <- tb.member_budgets}
                        id={"member-budget-#{team.id}-#{mb.member.id}"}
                      >
                        <td class="font-medium">{mb.member.user.email}</td>
                        <td class="text-center">
                          <% tier = get_member_tier(@usage_tiers_by_team, team.id, mb.member.id) %>
                          <%= if tier do %>
                            <span class={[
                              "badge badge-sm",
                              tier_badge_class(tier.tier)
                            ]} title={"Score: #{tier.score} | Peak RPM: #{tier.peak_rpm} | Días activos: #{tier.active_days}"}>
                              {String.capitalize(tier.tier)}
                            </span>
                          <% else %>
                            <span class="badge badge-sm badge-ghost" title="Sin actividad en 30 días">—</span>
                          <% end %>
                        </td>
                        <td class="text-right font-mono">
                          {team.default_concurrency_limit}
                          <span :if={mb.member.extra_concurrency} class="text-success">
                            +{mb.member.extra_concurrency}
                          </span>
                        </td>
                        <td class="text-right font-mono">
                          {team.default_rpm_limit}
                          <span :if={mb.member.extra_rpm} class="text-success">
                            +{mb.member.extra_rpm}
                          </span>
                        </td>
                        <td class="text-right font-mono">${format_decimal(mb.monthly_spend_usd)}</td>
                        <td class="text-right font-mono">
                          ${format_decimal(mb.monthly_limit_usd)}
                          <span :if={mb.member.extra_monthly_budget_usd} class="text-success">
                            +{format_decimal(mb.member.extra_monthly_budget_usd)}
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>

              <div class="mt-4 pt-4 border-t border-base-300">
                <h4 class="text-sm font-semibold mb-2">Aliases de modelos</h4>
                <div class="flex flex-wrap gap-2" id={"aliases-#{team.id}"}>
                  <button
                    :for={alias <- Map.get(@aliases_by_org, "all", [])}
                    type="button"
                    phx-click="toggle_alias"
                    phx-value-team-id={team.id}
                    phx-value-alias-id={alias.id}
                    class={[
                      "badge badge-sm cursor-pointer transition-all",
                      if(alias.id in granted_alias_ids(@granted_aliases, team.id),
                        do: "badge-primary",
                        else: "badge-outline"
                      )
                    ]}
                    id={"alias-#{team.id}-#{alias.id}"}
                  >
                    {alias.name}
                  </button>
                  <p
                    :if={Map.get(@aliases_by_org, "all", []) == []}
                    class="text-xs text-base-content/40"
                  >
                    No hay aliases disponibles.
                  </p>
                </div>
              </div>

              <!-- Webhooks section -->
              <div class="mt-4 pt-4 border-t border-base-300">
                <div class="flex items-center justify-between mb-3">
                  <h4 class="text-sm font-semibold flex items-center gap-1.5">
                    <.icon name="hero-bell-alert" class="w-4 h-4 opacity-70" />
                    Webhooks de observabilidad
                  </h4>
                  <button
                    phx-click="new_webhook"
                    phx-value-team-id={team.id}
                    class="btn btn-xs btn-ghost gap-1 transition-colors hover:text-primary"
                    id={"new-webhook-#{team.id}"}
                  >
                    <.icon name="hero-plus" class="w-3.5 h-3.5" /> Agregar webhook
                  </button>
                </div>

                <!-- Destination list -->
                <div id={"webhooks-list-#{team.id}"}>
                  <div
                    :for={destination <- Map.get(@destinations_by_team, team.id, [])}
                    class="flex items-center justify-between gap-3 py-2 px-3 rounded-lg bg-base-200/50 hover:bg-base-200 transition-colors mb-2"
                    id={"webhook-#{destination.id}"}
                  >
                    <div class="flex items-center gap-3 min-w-0">
                      <span class="badge badge-sm badge-primary/20 border-primary/30 text-primary">
                        {destination.type}
                      </span>
                      <div class="min-w-0">
                        <p class="text-sm font-medium truncate">{destination.name}</p>
                        <p class="text-xs text-base-content/40 truncate">{destination.url}</p>
                      </div>
                    </div>
                    <div class="flex gap-1 shrink-0">
                      <button
                        phx-click="edit_webhook"
                        phx-value-team-id={team.id}
                        phx-value-webhook-id={destination.id}
                        class="btn btn-xs btn-ghost"
                        id={"edit-webhook-#{destination.id}"}
                        title="Editar webhook"
                      >
                        <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                      </button>
                      <button
                        phx-click="delete_webhook"
                        phx-value-webhook-id={destination.id}
                        class="btn btn-xs btn-ghost text-error"
                        id={"delete-webhook-#{destination.id}"}
                        data-confirm="¿Eliminar webhook? Esta acción no se puede deshacer."
                        title="Eliminar webhook"
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" />
                      </button>
                    </div>
                  </div>

                  <div
                    :if={Map.get(@destinations_by_team, team.id, []) == []}
                    class="text-center py-6 text-base-content/40"
                    id={"webhooks-empty-#{team.id}"}
                  >
                    <.icon name="hero-bell-slash" class="w-8 h-8 mx-auto mb-1.5 opacity-40" />
                    <p class="text-xs">No hay webhooks configurados para este equipo.</p>
                  </div>
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
