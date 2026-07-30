defmodule TokengateWeb.TeamMembersLive do
  @moduledoc """
  Per-team member management.

  Access:
    - admin: manages members of any team.
    - user: denied — redirected to /dashboard.

  Supports:
    - Add member by email (creates team_member + auto-generates API key).
    - Remove member.
    - Per-member extras: extra_monthly_budget_usd,
      extra_concurrency, extra_rpm, extra_model_aliases (individual grants
      beyond team aliases) with optional per-model daily budget.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Providers
  alias Tokengate.Providers.{ModelAlias, TeamMemberExtraAlias, TeamModelAlias}
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
          |> assign(:new_token, nil)
          |> assign(:new_token_member_id, nil)
          |> assign(:show_add_modal?, false)
          |> assign(:add_form, add_member_form())
          |> assign(:add_member_error, nil)
          |> assign(:email_suggestions, [])
          |> assign(:member_search, "")
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

  defp check_access(_user, _team) do
    {:denied, "No tienes permisos para gestionar este equipo."}
  end

  ## Data loading ---------------------------------------------------------

  defp load_data(socket) do
    team = socket.assigns.team
    search = socket.assigns[:member_search] || ""
    members = Accounts.list_team_members_for_team(team.id)

    members =
      if search == "" do
        members
      else
        search_down = String.downcase(search)
        Enum.filter(members, fn m ->
          String.contains?(String.downcase(m.user.email), search_down) or
            String.contains?(String.downcase(m.user.name || ""), search_down)
        end)
      end

    # Get all available model aliases
    org_alias_ids =
      from(ma in ModelAlias,
        order_by: [asc: ma.name]
      )
      |> Repo.all()

    # Get the team's own aliases (from team_model_aliases)
    team_alias_ids =
      from(tma in TeamModelAlias,
        where: tma.team_id == ^team.id,
        select: tma.model_alias_id
      )
      |> Repo.all()
      |> MapSet.new()

    # Preload extra alias ids per member (access grants only, no budget)
    extra_aliases =
      from(tmea in TeamMemberExtraAlias,
        where: tmea.team_member_id in ^Enum.map(members, & &1.id),
        select: {tmea.team_member_id, tmea.model_alias_id}
      )
      |> Repo.all()

    extra_aliases_simple =
      extra_aliases
      |> Enum.group_by(fn {tm_id, _} -> tm_id end, fn {_, alias_id} -> alias_id end)

    # Member budgets with spend
    alias_map = Map.new(org_alias_ids, fn a -> {a.id, a.name} end)

    member_budgets =
      Enum.map(members, fn m ->
        budget_for_member(m, alias_map)
      end)

    team_monthly_spend =
      Enum.reduce(members, Decimal.new(0), fn m, acc ->
        spend = Tokengate.Budgets.Manager.spend(m.id)
        Decimal.add(acc, spend.monthly_usd)
      end)

    estimated_monthly =
      if team.monthly_budget_per_user_usd do
        team.monthly_budget_per_user_usd
        |> Decimal.mult(Decimal.new(length(members)))
      else
        nil
      end

    estimated_monthly_extra =
      Enum.reduce(members, Decimal.new(0), fn m, acc ->
        if m.extra_monthly_budget_usd,
          do: Decimal.add(acc, m.extra_monthly_budget_usd),
          else: acc
      end)

    socket
    |> assign(:members, members)
    |> assign(:member_budgets, Map.new(member_budgets, fn b -> {b.member_id, b} end))
    |> assign(:members_empty?, members == [])
    |> assign(:org_aliases, org_alias_ids)
    |> assign(:team_alias_ids, team_alias_ids)
    |> assign(:extra_aliases, extra_aliases_simple)
    |> assign(:alias_map, alias_map)
    |> assign(:team_monthly_spend, team_monthly_spend)
    |> assign(:estimated_monthly, estimated_monthly)
    |> assign(:estimated_monthly_extra, estimated_monthly_extra)
  end

  defp budget_for_member(member, _alias_map) do
    spend = Tokengate.Budgets.Manager.spend(member.id)

    %{
      member_id: member.id,
      monthly_spend: spend.monthly_usd
    }
  end

  ## Events — add member --------------------------------------------------

  @impl true
  def handle_event("search_members", %{"member_search" => search}, socket) do
    {:noreply, socket |> assign(:member_search, search) |> load_data()}
  end

  @impl true
  def handle_event("new_member", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal?, true)
     |> assign(:add_form, add_member_form())
     |> assign(:add_member_error, nil)}
  end

  @impl true
  def handle_event("cancel_add_member", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal?, false)
     |> assign(:add_form, add_member_form())
     |> assign(:add_member_error, nil)
     |> assign(:email_suggestions, [])}
  end

  @impl true
  def handle_event("search_email", %{"add_member" => %{"email" => query}}, socket) do
    suggestions =
      case String.trim(query) do
        "" -> []
        trimmed when byte_size(trimmed) < 2 -> []
        trimmed -> Accounts.search_users(trimmed)
      end

    {:noreply, assign(socket, :email_suggestions, suggestions)}
  end

  @impl true
  def handle_event("select_email", %{"email" => email}, socket) do
    form =
      socket.assigns.add_form
      |> Map.update!(:params, fn params -> Map.put(params, "email", email) end)

    {:noreply,
     socket
     |> assign(:add_form, to_form(form.params, as: :add_member))
     |> assign(:email_suggestions, [])}
  end

  @impl true
  def handle_event("add_member", %{"add_member" => params}, socket) do
    team = socket.assigns.team

    with {:ok, email} <- Map.fetch(params, "email"),
         {:ok, user} <- fetch_user_by_email(email),
         {:ok, monthly} <- parse_decimal(params["extra_monthly_budget_usd"]),
         {:ok, concurrency} <- parse_integer(params["extra_concurrency"]),
         {:ok, rpm} <- parse_integer(params["extra_rpm"]) do
      attrs = %{
        user_id: user.id,
        team_id: team.id,
        team_role: "user",
        extra_monthly_budget_usd: monthly,
        extra_concurrency: concurrency,
        extra_rpm: rpm
      }

      case Accounts.create_team_member(attrs) do
        {:ok, _member} ->
          {:noreply,
           socket
           |> put_flash(:info, "Miembro añadido. Genera su API key desde la sección API Keys.")
           |> assign(:show_add_modal?, false)
           |> assign(:add_form, add_member_form())
           |> assign(:add_member_error, nil)
           |> load_data()}

        {:error, changeset} ->
          msg = format_changeset_errors(changeset)

          {:noreply,
           socket
           |> assign(:add_member_error, msg)
           |> assign(:add_form, to_form(params, as: :add_member))}
      end
    else
      :error ->
        {:noreply,
         socket
         |> assign(:add_member_error, "Valores inválidos: revisa que sean números válidos.")
         |> assign(:add_form, to_form(params, as: :add_member))}

      nil ->
        {:noreply,
         socket
         |> assign(:add_member_error, "No existe un usuario con ese email.")
         |> assign(:add_form, to_form(params, as: :add_member))}
    end
  end

  @impl true
  def handle_event("clear_sticky_routes", %{"id" => member_id}, socket) do
    member = Accounts.get_team_member!(member_id, :with_assoc)

    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
      Accounts.clear_team_member_sticky_routes(member)

      {:noreply,
       socket
       |> put_flash(
         :info,
         "Sticky routes limpiadas para #{member.user.email}. Su próxima petición se re-ruteará."
       )
       |> load_data()}
    end
  end

  ## Events — remove member ----------------------------------------------

  @impl true
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

  ## Events — API key management --------------------------------------------

  @impl true
  def handle_event("replace_key", %{"id" => member_id}, socket) do
    member = Accounts.get_team_member!(member_id)

    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
      case Accounts.replace_api_key(member) do
        {:ok, _api_key, new_token} ->
          {:noreply,
           socket
           |> assign(:new_token, new_token)
           |> assign(:new_token_member_id, member_id)
           |> put_flash(:info, "Clave regenerada correctamente.")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo regenerar la clave.")}
      end
    end
  end

  @impl true
  def handle_event("revoke_key", %{"id" => member_id}, socket) do
    member = Accounts.get_team_member!(member_id, :with_assoc)

    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
      case member.api_key do
        nil ->
          {:noreply, put_flash(socket, :error, "Esta membresía no tiene clave.")}

        api_key ->
          case Accounts.revoke_api_key(api_key) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Clave revocada.")
               |> load_data()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
          end
      end
    end
  end

  @impl true
  def handle_event("dismiss_new_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  ## Events — override edits ---------------------------------------------

  @impl true
  def handle_event("edit_overrides", %{"id" => member_id}, socket) do
    {:noreply, assign(socket, :editing_member_id, member_id)}
  end

  @impl true
  def handle_event("cancel_overrides", _params, socket) do
    {:noreply, assign(socket, :editing_member_id, nil)}
  end

  @impl true
  def handle_event("save_overrides", %{"overrides" => override_params} = params, socket) do
    member_id = params["id"]
    member = Accounts.get_team_member!(member_id)

    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
      with {:ok, monthly} <- parse_decimal(override_params["extra_monthly_budget_usd"]),
           {:ok, concurrency} <- parse_integer(override_params["extra_concurrency"]),
           {:ok, rpm} <- parse_integer(override_params["extra_rpm"]) do
        attrs = %{
          extra_monthly_budget_usd: monthly,
          extra_concurrency: concurrency,
          extra_rpm: rpm
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
      else
        :error ->
          {:noreply,
           put_flash(socket, :error, "Valores inválidos: revisa que sean números válidos.")}
      end
    end
  end

  ## Events — extra alias grants -----------------------------------------

  @impl true
  def handle_event(
        "toggle_extra_alias",
        %{"member-id" => member_id, "alias-id" => alias_id},
        socket
      ) do
    member = Accounts.get_team_member!(member_id)

    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
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

  @impl true
  def handle_event(
        "save_alias_extra",
        %{"alias_extra" => params},
        socket
      ) do
    member_id = params["member_id"]
    alias_id = params["alias_id"]

    member = Accounts.get_team_member!(member_id)

    if member.team_id != socket.assigns.team.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este equipo.")}
    else
      case Providers.set_extra_alias(member_id, alias_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Alias actualizado.")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo actualizar el alias.")}
      end
    end
  end

  ## Helpers --------------------------------------------------------------

  defp parse_decimal(""), do: {:ok, nil}
  defp parse_decimal(nil), do: {:ok, nil}
  defp parse_decimal(%Decimal{} = d), do: {:ok, d}

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp parse_decimal(_), do: :error

  defp parse_integer(""), do: {:ok, nil}
  defp parse_integer(nil), do: {:ok, nil}
  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_integer(_), do: :error

  defp add_member_form do
    to_form(
      %{
        "email" => "",
        "extra_monthly_budget_usd" => "",
        "extra_concurrency" => "",
        "extra_rpm" => ""
      },
      as: :add_member
    )
  end

  defp fetch_user_by_email(email) do
    case Accounts.get_user_by_email(email) do
      nil -> nil
      user -> {:ok, user}
    end
  end

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

  defp format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  defp format_decimal(nil), do: "—"
  defp format_decimal(value), do: to_string(value)

  defp masked_key(%{api_key: %{key_prefix: prefix}}) when is_binary(prefix), do: "#{prefix}••••"
  defp masked_key(_), do: "Sin clave"

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
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

        <div class="flex justify-end">
          <button phx-click="new_member" class="btn btn-primary btn-sm" id="new-member-btn">
            <.icon name="hero-plus" class="w-4 h-4" /> Añadir miembro
          </button>
        </div>

        <%!-- Add member modal --%>
        <div
          :if={@show_add_modal?}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id="add-member-modal"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_add_member" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">Añadir miembro</h2>
              <.form for={@add_form} id="add-member-form" phx-submit="add_member">
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <%!-- Email input with live autocomplete --%>
                  <div class="sm:col-span-2 relative">
                    <.input
                      field={@add_form[:email]}
                      type="email"
                      label="Email del usuario"
                      placeholder="usuario@ejemplo.com"
                      phx-change="search_email"
                      phx-debounce="300"
                    />
                    <div
                      :if={@email_suggestions != []}
                      class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-60 overflow-y-auto"
                      id="email-suggestions"
                    >
                      <button
                        :for={user <- @email_suggestions}
                        type="button"
                        phx-click="select_email"
                        phx-value-email={user.email}
                        class="w-full text-left px-3 py-2 hover:bg-base-200 transition-colors flex items-center gap-3 border-b border-base-200 last:border-0"
                        id={"suggestion-#{user.id}"}
                      >
                        <div class="flex-1 min-w-0">
                          <p class="text-sm font-medium truncate">{user.email}</p>
                          <p class="text-xs text-base-content/50 truncate">{user.name}</p>
                        </div>
                        <span class={["badge", "badge-sm", "badge-ghost"]}>{user.global_role}</span>
                      </button>
                    </div>
                  </div>
                  <.input
                    field={@add_form[:extra_monthly_budget_usd]}
                    type="number"
                    label="Extra mensual (USD)"
                    step="any"
                    placeholder="0.00"
                  />
                  <.input
                    field={@add_form[:extra_concurrency]}
                    type="number"
                    label="Extra concurrencia"
                    placeholder="0"
                  />
                  <.input
                    field={@add_form[:extra_rpm]}
                    type="number"
                    label="Extra RPM"
                    placeholder="0"
                  />
                </div>
                <p :if={@add_member_error} class="text-sm text-error mt-4" id="add-member-error">
                  <.icon name="hero-exclamation-circle" class="w-4 h-4 inline mr-1" />
                  {@add_member_error}
                </p>
                <div class="flex gap-2 mt-6 justify-end">
                  <button
                    type="button"
                    phx-click="cancel_add_member"
                    class="btn btn-ghost btn-sm"
                    id="cancel-add-member"
                  >
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="add-member-btn-submit">
                    Añadir
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Overrides form (modal) --%>
        <div
          :if={@editing_member_id}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id={"overrides-form-#{@editing_member_id}"}
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_overrides" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">Extras del miembro</h2>
              <% member = Enum.find(@members, &(&1.id == @editing_member_id)) %>
              <.form
                :if={member}
                for={
                  to_form(%{
                    "extra_monthly_budget_usd" =>
                      if(member.extra_monthly_budget_usd,
                        do: Decimal.to_string(member.extra_monthly_budget_usd),
                        else: ""
                      ),
                    "extra_concurrency" =>
                      if(member.extra_concurrency,
                        do: to_string(member.extra_concurrency),
                        else: ""
                      ),
                    "extra_rpm" => if(member.extra_rpm, do: to_string(member.extra_rpm), else: "")
                  })
                }
                id={"override-form-#{@editing_member_id}"}
                phx-submit="save_overrides"
                phx-value-id={@editing_member_id}
              >
                <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                  <.input
                    field={to_form(%{})[:extra_monthly_budget_usd]}
                    type="number"
                    label="Extra mensual (USD)"
                    step="any"
                    name="overrides[extra_monthly_budget_usd]"
                    value={
                      if(member.extra_monthly_budget_usd,
                        do: Decimal.to_string(member.extra_monthly_budget_usd),
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
                    value={if(member.extra_rpm, do: to_string(member.extra_rpm), else: "")}
                  />
                </div>
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_overrides" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button
                    type="submit"
                    class="btn btn-primary btn-sm"
                    id={"save-overrides-#{@editing_member_id}"}
                  >
                    Guardar
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Resumen del equipo — configuración + gasto --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="team-config">
          <div class="card-body p-5">
            <h2 class="text-sm font-semibold mb-3">Resumen del equipo</h2>

            <%!-- Stats cards: configuración + gasto — 5 tarjetas --%>
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
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
                    ${format_decimal(@team.monthly_budget_per_user_usd)}
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
                    {@team.default_concurrency_limit}
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
                    {@team.default_rpm_limit}
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
                    ${format_decimal(@team_monthly_spend)}
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
                        @estimated_monthly_extra &&
                          Decimal.compare(@estimated_monthly_extra, 0) == :gt,
                        do: "bg-success/10",
                        else: "bg-primary/10"
                      )
                    ]}>
                      <.icon
                        name="hero-calculator"
                        class={[
                          "w-4 h-4",
                          if(
                            @estimated_monthly_extra &&
                              Decimal.compare(@estimated_monthly_extra, 0) == :gt,
                            do: "text-success",
                            else: "text-primary"
                          )
                        ]}
                      />
                    </span>
                  </div>
                  <p class="mt-1.5 text-lg font-bold text-base-content">
                    ${format_decimal(
                      Decimal.add(@estimated_monthly || Decimal.new(0), @estimated_monthly_extra)
                    )}
                  </p>
                  <p
                    :if={
                      @estimated_monthly_extra && Decimal.compare(@estimated_monthly_extra, 0) == :gt
                    }
                    class="text-xs text-success"
                  >
                    ${format_decimal(@estimated_monthly)} base + ${format_decimal(
                      @estimated_monthly_extra
                    )} extra
                  </p>
                  <p
                    :if={
                      !(@estimated_monthly_extra &&
                          Decimal.compare(@estimated_monthly_extra, 0) == :gt)
                    }
                    class="text-xs text-base-content/40"
                  >
                    proyección
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="flex items-center justify-end gap-3 mb-4">
          <input
            type="text"
            name="member_search"
            value={@member_search}
            placeholder="Buscar por nombre o correo…"
            phx-change="search_members"
            phx-debounce="200"
            class="input input-sm w-72"
          />
        </div>

        <div id="members" class="space-y-4">
          <div :if={@members_empty?} class="text-center py-12 text-base-content/40" id="members-empty">
            <.icon name="hero-users" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>Este equipo no tiene miembros todavía.</p>
          </div>
          <div
            :for={member <- @members}
            id={"members-#{member.id}"}
            class="card bg-base-100 border border-base-300 shadow-sm"
          >
            <% mb =
              Map.get(@member_budgets, member.id, %{
                daily_spend: Decimal.new(0),
                member_extra: Decimal.new(0),
                model_extras: [],
                model_extra_total: Decimal.new(0),
                total_max: Decimal.new(0)
              }) %>
            <div class="card-body p-5">
              <%!-- Header with API key info --%>
              <div class="flex items-start justify-between">
                <div class="min-w-0">
                  <h3 class="font-semibold text-base-content truncate">{member.user.email}</h3>
                  <div class="flex items-center gap-2 mt-0.5 flex-wrap">
                    <span class="text-xs text-base-content/50">{member.user.name}</span>
                    <span class="text-xs text-base-content/30">·</span>
                    <code class="text-xs font-mono">{masked_key(member)}</code>
                    <%= if member.api_key do %>
                      <span class={[
                        "badge badge-xs",
                        if(member.api_key.status == "active",
                          do: "badge-success",
                          else: "badge-error"
                        )
                      ]}>
                        {if(member.api_key.status == "active", do: "Activa", else: "Revocada")}
                      </span>
                    <% else %>
                      <span class="badge badge-xs badge-ghost">Sin clave</span>
                    <% end %>
                  </div>
                </div>
                <div class="flex items-center gap-5 shrink-0">
                  <span class="badge badge-sm badge-ghost capitalize">{member.status}</span>
                  <button
                    phx-click="clear_sticky_routes"
                    phx-value-id={member.id}
                    class="btn btn-sm btn-ghost"
                    id={"clear-sticky-#{member.id}"}
                    title="Fuerza re-ruteo en la siguiente petición"
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> Sticky
                  </button>
                  <button
                    phx-click="replace_key"
                    phx-value-id={member.id}
                    class="btn btn-sm btn-ghost"
                    id={"replace-key-#{member.id}"}
                    data-confirm="¿Regenerar clave? La clave actual dejará de funcionar inmediatamente."
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> Regenerar
                  </button>
                  <%= if member.api_key && member.api_key.status == "active" do %>
                    <button
                      phx-click="revoke_key"
                      phx-value-id={member.id}
                      class="btn btn-sm btn-ghost text-error"
                      id={"revoke-key-#{member.id}"}
                      data-confirm="¿Revocar clave? Esta acción no se puede deshacer."
                    >
                      <.icon name="hero-no-symbol" class="w-4 h-4" /> Revocar
                    </button>
                  <% end %>
                </div>
              </div>

              <%!-- New token reveal (after regenerate) --%>
              <div
                :if={@new_token && @new_token_member_id == member.id}
                class="mt-3 alert alert-warning"
                id={"new-token-#{member.id}"}
              >
                <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
                <div class="flex-1 text-sm">
                  <p class="font-semibold">Guarda esta clave ahora — no se volverá a mostrar:</p>
                  <code class="text-xs font-mono break-all">{@new_token}</code>
                </div>
                <button
                  phx-click="dismiss_new_token"
                  class="btn btn-sm btn-ghost"
                  id={"dismiss-token-#{member.id}"}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>

              <%!-- Stats cards: configuración + gasto del miembro — 4 tarjetas --%>
              <div class="mt-4 grid grid-cols-2 sm:grid-cols-4 gap-3">
                <%!-- Budget mensual --%>
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
                      ${format_decimal(@team.monthly_budget_per_user_usd)}
                    </p>
                    <p :if={member.extra_monthly_budget_usd} class="text-xs text-success">
                      +${format_decimal(member.extra_monthly_budget_usd)} extra
                    </p>
                    <p :if={!member.extra_monthly_budget_usd} class="text-xs text-base-content/40">
                      por usuario
                    </p>
                  </div>
                </div>

                <%!-- Concurrencia --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Concurrencia
                      </span>
                      <span class={[
                        "flex items-center justify-center w-8 h-8 rounded-lg",
                        if(member.extra_concurrency, do: "bg-success/10", else: "bg-accent/10")
                      ]}>
                        <.icon
                          name="hero-arrows-right-left"
                          class={[
                            "w-4 h-4",
                            if(member.extra_concurrency, do: "text-success", else: "text-accent")
                          ]}
                        />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {@team.default_concurrency_limit}
                    </p>
                    <p :if={member.extra_concurrency} class="text-xs text-success">
                      +{member.extra_concurrency} extra
                    </p>
                    <p :if={!member.extra_concurrency} class="text-xs text-base-content/40">
                      por usuario
                    </p>
                  </div>
                </div>

                <%!-- RPM --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        RPM
                      </span>
                      <span class={[
                        "flex items-center justify-center w-8 h-8 rounded-lg",
                        if(member.extra_rpm, do: "bg-success/10", else: "bg-accent/10")
                      ]}>
                        <.icon
                          name="hero-bolt"
                          class={[
                            "w-4 h-4",
                            if(member.extra_rpm, do: "text-success", else: "text-accent")
                          ]}
                        />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {@team.default_rpm_limit}
                    </p>
                    <p :if={member.extra_rpm} class="text-xs text-success">
                      +{member.extra_rpm} extra
                    </p>
                    <p :if={!member.extra_rpm} class="text-xs text-base-content/40">
                      por usuario
                    </p>
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
                      ${format_decimal(mb.monthly_spend)}
                    </p>
                    <p class="text-xs text-base-content/40">real</p>
                  </div>
                </div>
              </div>

              <%!-- Actions --%>
              <div class="flex flex-wrap items-center justify-between gap-2 mt-3">
                <div class="flex items-center gap-2">
                  <button
                    phx-click="edit_overrides"
                    phx-value-id={member.id}
                    class="btn btn-sm btn-ghost"
                    id={"edit-overrides-#{member.id}"}
                  >Extras</button>
                </div>
                <button
                  phx-click="remove_member"
                  phx-value-id={member.id}
                  class="btn btn-sm btn-ghost text-error"
                  id={"remove-#{member.id}"}
                >Eliminar</button>
              </div>

              <%!-- Modelos — team aliases (locked) + extra grants (toggleable) --%>
              <div :if={@org_aliases != []} class="mt-3 pt-3 border-t border-base-200">
                <p class="text-xs text-base-content/50 uppercase tracking-wide mb-2">Modelos</p>
                <div class="flex flex-wrap gap-2">
                  <button
                    :for={alias <- @org_aliases}
                    type="button"
                    phx-click={not MapSet.member?(@team_alias_ids, alias.id) and "toggle_extra_alias"}
                    phx-value-member-id={member.id}
                    phx-value-alias-id={alias.id}
                    class={[
                      "badge badge-sm cursor-pointer transition-all",
                      cond do
                        MapSet.member?(@team_alias_ids, alias.id) -> "badge-primary"
                        alias.id in extra_alias_ids(@extra_aliases, member.id) -> "badge-accent"
                        true -> "badge-outline"
                      end
                    ]}
                    disabled={MapSet.member?(@team_alias_ids, alias.id)}
                    id={"extra-alias-#{member.id}-#{alias.id}"}
                  >
                    {alias.name}
                    <%= if MapSet.member?(@team_alias_ids, alias.id) do %>
                      <span class="text-[10px] opacity-60 ml-0.5">equipo</span>
                    <% end %>
                  </button>
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
