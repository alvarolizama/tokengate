defmodule TokengateWeb.GroupMembersLive do
  @moduledoc """
  Per-group member management.

  Access:
    - admin: manages members of any group.
    - user: denied — redirected to /dashboard.

  Supports:
    - Add member by email (creates group_member + auto-generates API key).
    - Remove member.
    - Per-member extras: extra_concurrency, extra_rpm,
      extra_model_models (individual grants
      beyond group models) with optional per-model daily budget.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Accounts
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Providers
  alias Tokengate.Providers.{Model, GroupMemberExtraModel, GroupMemberDeniedModel, GroupModel}
  alias Tokengate.Repo

  @impl true
  def mount(%{"id" => group_id}, _session, socket) do
    user = socket.assigns[:current_user]
    group = Accounts.get_group!(group_id)

    case check_access(user, group) do
      :ok ->
        socket =
          socket
          |> assign(:page_title, "Miembros · Tokengate")
          |> assign(:group, group)
          |> assign(:editing_member_id, nil)
          |> assign(:editing_details_member_id, nil)
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

  defp check_access(%{global_role: "admin"}, _group), do: :ok

  defp check_access(_user, _group) do
    {:denied, "No tienes permisos para gestionar este grupo."}
  end

  ## Data loading ---------------------------------------------------------

  defp load_data(socket) do
    group = socket.assigns.group
    search = socket.assigns[:member_search] || ""
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    members = Accounts.list_group_members_for_group(group.id)

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

    # Get all available models
    org_alias_ids =
      from(ma in Model,
        order_by: [asc: ma.name]
      )
      |> Repo.all()

    # Get the group's own models (from group_models)
    group_alias_ids =
      from(tma in GroupModel,
        where: tma.group_id == ^group.id,
        select: tma.model_id
      )
      |> Repo.all()
      |> MapSet.new()

    # Preload extra model ids per member (access grants only, no budget)
    extra_models =
      from(tmea in GroupMemberExtraModel,
        where: tmea.group_member_id in ^Enum.map(members, & &1.id),
        select: {tmea.group_member_id, tmea.model_id}
      )
      |> Repo.all()

    extra_aliases_simple =
      extra_models
      |> Enum.group_by(fn {tm_id, _} -> tm_id end, fn {_, model_id} -> model_id end)

    # Per-member denied model ids (3rd picker state: "quitado")
    denied_models =
      from(tmda in GroupMemberDeniedModel,
        where: tmda.group_member_id in ^Enum.map(members, & &1.id),
        select: {tmda.group_member_id, tmda.model_id}
      )
      |> Repo.all()
      |> Enum.group_by(fn {tm_id, _} -> tm_id end, fn {_, model_id} -> model_id end)

    # Member budgets with spend — one batched query for every member instead
    # of one SUM per member (N+1).
    model_map = Map.new(org_alias_ids, fn a -> {a.id, a.name} end)

    monthly_spend_by_member =
      members
      |> Enum.map(& &1.id)
      |> Tokengate.Budgets.spend_by_member_ids(timezone)
      |> Map.get(:monthly)

    member_budgets =
      Enum.map(members, fn m ->
        %{
          member_id: m.id,
          monthly_spend: Map.get(monthly_spend_by_member, m.id, Decimal.new(0))
        }
      end)

    group_monthly_spend =
      Enum.reduce(monthly_spend_by_member, Decimal.new(0), fn {_id, spend}, acc ->
        Decimal.add(acc, spend)
      end)

    # Usage tiers for this group (last 30 days)
    usage_tiers = Rollup.member_usage_tiers(group.id, from: days_ago(30))

    socket
    |> assign(:members, members)
    |> assign(:member_budgets, Map.new(member_budgets, fn b -> {b.member_id, b} end))
    |> assign(:members_empty?, members == [])
    |> assign(:org_models, org_alias_ids)
    |> assign(:group_alias_ids, group_alias_ids)
    |> assign(:extra_models, extra_aliases_simple)
    |> assign(:denied_models, denied_models)
    |> assign(:model_map, model_map)
    |> assign(:group_monthly_spend, group_monthly_spend)
    |> assign(:usage_tiers, usage_tiers)
    |> load_exclusive_providers(members)
  end

  defp days_ago(n) do
    DateTime.add(DateTime.utc_now(), -n * 86400, :second)
  end

  defp load_exclusive_providers(socket, members) do
    member_ids = Enum.map(members, & &1.id)

    # Query exclusive providers where any member in this group is the target
    import Ecto.Query, only: [from: 2]
    alias Tokengate.Providers.ModelProvider

    exclusive_providers =
      from(mp in ModelProvider,
        where: mp.exclusive_to_group_member_id in ^member_ids,
        preload: [credential: [:provider], model: []]
      )
      |> Repo.all()

    # Group by member_id for easy lookup
    grouped =
      exclusive_providers
      |> Enum.group_by(& &1.exclusive_to_group_member_id)

    assign(socket, :exclusive_providers, grouped)
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
    group = socket.assigns.group

    with {:ok, email} <- Map.fetch(params, "email"),
         {:ok, user} <- fetch_user_by_email(email),
         {:ok, concurrency} <- parse_integer(params["extra_concurrency"]),
         {:ok, rpm} <- parse_integer(params["extra_rpm"]) do
      attrs = %{
        user_id: user.id,
        group_id: group.id,
        extra_concurrency: concurrency,
        extra_rpm: rpm
      }

      case Accounts.create_group_member(attrs) do
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
    member = Accounts.get_group_member!(member_id, :with_assoc)

    if member.group_id != socket.assigns.group.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este grupo.")}
    else
      Accounts.clear_group_member_sticky_routes(member)

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
    member = Accounts.get_group_member!(member_id)

    # Verify the member belongs to this group
    if member.group_id != socket.assigns.group.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este grupo.")}
    else
      case Accounts.delete_group_member(member) do
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
    member = Accounts.get_group_member!(member_id)

    if member.group_id != socket.assigns.group.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este grupo.")}
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
    member = Accounts.get_group_member!(member_id, :with_assoc)

    if member.group_id != socket.assigns.group.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este grupo.")}
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
  def handle_event("open_details", %{"id" => member_id}, socket) do
    {:noreply, assign(socket, :editing_details_member_id, member_id)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, :editing_details_member_id, nil)}
  end

  @impl true
  def handle_event("cancel_overrides", _params, socket) do
    {:noreply, assign(socket, :editing_member_id, nil)}
  end

  @impl true
  def handle_event("save_overrides", %{"overrides" => override_params} = params, socket) do
    member_id = params["id"]
    member = Accounts.get_group_member!(member_id)

    if member.group_id != socket.assigns.group.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este grupo.")}
    else
      with {:ok, concurrency} <- parse_integer(override_params["extra_concurrency"]),
           {:ok, rpm} <- parse_integer(override_params["extra_rpm"]) do
        attrs = %{
          extra_concurrency: concurrency,
          extra_rpm: rpm
        }

        case Accounts.update_group_member(member, attrs) do
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

  ## Events — extra model grants / denies (picker de 3 estados) ------------

  @impl true
  def handle_event(
        "toggle_extra_model",
        %{"target-id" => member_id, "model-id" => model_id},
        socket
      ) do
    member = Accounts.get_group_member!(member_id)

    if member.group_id != socket.assigns.group.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este grupo.")}
    else
      existing = Map.get(socket.assigns.extra_models, member_id, [])
      denied = Map.get(socket.assigns.denied_models, member_id, [])

      result =
        cond do
          # Estado "quitado" → permitir de nuevo (borra el deny).
          model_id in denied ->
            Providers.allow_model(member_id, model_id)

          # Estado "heredado" o "agregado" → quitar. Un extra concedido aquí se
          # revoca además de denegarse: dejar el extra vivo lo resucitaría al
          # quitar el deny desde la UI (el union volvería a incluirlo).
          model_id in existing ->
            with {:ok, _} <- Providers.deny_model(member_id, model_id) do
              Providers.revoke_extra_model(member_id, model_id)
            end

          # Estado "sin acceso" → agregar como extra.
          true ->
            Providers.grant_extra_model(member_id, model_id)
        end

      case result do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Modelos actualizados.")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo actualizar el modelo.")}
      end
    end
  end

  @impl true
  def handle_event(
        "save_alias_extra",
        %{"model_extra" => params},
        socket
      ) do
    member_id = params["member_id"]
    model_id = params["model_id"]

    member = Accounts.get_group_member!(member_id)

    if member.group_id != socket.assigns.group.id do
      {:noreply, put_flash(socket, :error, "El miembro no pertenece a este grupo.")}
    else
      case Providers.set_extra_model(member_id, model_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Alias actualizado.")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo actualizar el modelo.")}
      end
    end
  end

  ## Helpers --------------------------------------------------------------

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

  defp extra_model_ids(extra_models, member_id) do
    Map.get(extra_models, member_id, [])
  end

  defp denied_model_ids(denied_models, member_id) do
    Map.get(denied_models, member_id, [])
  end

  defp format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  defp format_decimal(nil), do: "—"
  defp format_decimal(value), do: to_string(value)

  defp masked_key(%{api_key: %{key_prefix: prefix}}) when is_binary(prefix), do: "#{prefix}••••"
  defp masked_key(_), do: "Sin clave"

  defp get_member_tier(usage_tiers, member_id) do
    Enum.find(usage_tiers, &(&1.group_member_id == member_id))
  end

  defp tier_badge_class("alto"), do: "badge-error"
  defp tier_badge_class("regular"), do: "badge-warning"
  defp tier_badge_class("bajo"), do: "badge-ghost"
  defp tier_badge_class(_), do: "badge-ghost"

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="space-y-6">
        <.header>
          Miembros de {@group.name}
          <:subtitle>Añade miembros, gestiona roles y extras</:subtitle>
          <:actions>
            <.link navigate={~p"/access/groups"} class="btn btn-ghost" id="back-to-groups">
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

        <%!-- Resumen del grupo — fila compacta --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="group-config">
          <div class="card-body p-4">
            <div class="flex flex-wrap items-center gap-x-8 gap-y-3">
              <div>
                <p class="text-[10px] uppercase tracking-wide text-base-content/40">Concurrencia</p>
                <p class="text-lg font-bold">{@group.default_concurrency_limit}</p>
                <p class="text-xs text-base-content/40">por usuario</p>
              </div>
              <div>
                <p class="text-[10px] uppercase tracking-wide text-base-content/40">RPM</p>
                <p class="text-lg font-bold">{@group.default_rpm_limit}</p>
                <p class="text-xs text-base-content/40">por usuario</p>
              </div>
              <div>
                <p class="text-[10px] uppercase tracking-wide text-base-content/40">Gasto/mes</p>
                <p class="text-lg font-bold text-success">${format_decimal(@group_monthly_spend)}</p>
                <p class="text-xs text-base-content/40">real</p>
              </div>
            </div>
          </div>
        </div>

        <div id="members">
          <%!-- New token reveal (after regenerate) — banner above the table --%>
          <div
            :if={@new_token && @new_token_member_id}
            class="alert alert-warning mb-4"
            id={"new-token-#{@new_token_member_id}"}
          >
            <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
            <div class="flex-1 text-sm">
              <p class="font-semibold">Guarda esta clave ahora — no se volverá a mostrar:</p>
              <code class="text-xs font-mono break-all">{@new_token}</code>
            </div>
            <button
              phx-click="dismiss_new_token"
              class="btn btn-sm btn-ghost"
              id={"dismiss-token-#{@new_token_member_id}"}
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div
            :if={!@members_empty?}
            class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm"
          >
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Miembro</th>
                  <th>Límites</th>
                  <th>Modelos</th>
                  <th>Gasto/mes</th>
                  <th>Uso</th>
                  <th class="text-right">Acciones</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={member <- @members} id={"members-#{member.id}"} class="align-top">
                  <% mb = Map.get(@member_budgets, member.id, %{monthly_spend: Decimal.new(0)}) %>
                  <td>
                    <p class="font-medium text-sm">{member.user.email}</p>
                    <p class="text-xs text-base-content/50">{member.user.name}</p>
                    <div class="flex items-center gap-1.5 mt-1 flex-wrap">
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
                      <span class="badge badge-xs badge-ghost capitalize">{member.status}</span>
                    </div>
                  </td>
                  <td class="text-xs whitespace-nowrap">
                    <p>
                      <span class="text-base-content/50">Conc.</span>
                      {@group.default_concurrency_limit}
                      <span :if={member.extra_concurrency} class="text-success font-medium">
                        +{member.extra_concurrency}
                      </span>
                    </p>
                    <p>
                      <span class="text-base-content/50">RPM</span>
                      {@group.default_rpm_limit}
                      <span :if={member.extra_rpm} class="text-success font-medium">
                        +{member.extra_rpm}
                      </span>
                    </p>
                  </td>
                  <td>
                    <div class="flex items-center gap-1.5 flex-wrap">
                      <button
                        phx-click="open_details"
                        phx-value-id={member.id}
                        class="badge badge-sm badge-outline gap-1 hover:badge-primary cursor-pointer transition-colors"
                        id={"details-#{member.id}"}
                        title="Modelos y API keys exclusivas"
                      >
                        <.icon name="hero-rectangle-stack" class="w-3 h-3" />
                        {length(MapSet.to_list(@group_alias_ids))} grupo
                      </button>
                      <span
                        :if={extra_model_ids(@extra_models, member.id) != []}
                        class="badge badge-sm badge-accent"
                      >
                        +{length(extra_model_ids(@extra_models, member.id))} extra
                      </span>
                    </div>
                  </td>
                  <td class="font-mono text-sm">${format_decimal(mb.monthly_spend)}</td>
                  <td>
                    <% tier = get_member_tier(@usage_tiers, member.id) %>
                    <%= if tier do %>
                      <span
                        class={["badge badge-sm", tier_badge_class(tier.tier)]}
                        title={"Score: #{tier.score} | Peak RPM: #{tier.peak_rpm} | Días activos: #{tier.active_days} | Requests: #{tier.request_count}"}
                      >
                        {String.capitalize(tier.tier)}
                      </span>
                    <% else %>
                      <span class="badge badge-sm badge-ghost" title="Sin actividad en 30 días">—</span>
                    <% end %>
                  </td>
                  <td class="text-right">
                    <div class="flex gap-0.5 justify-end">
                      <.link
                        navigate={~p"/stats/users/#{member.user_id}"}
                        class="btn btn-xs btn-ghost"
                        id={"stats-#{member.id}"}
                        title="Ver stats consolidados de este usuario"
                      >
                        <.icon name="hero-chart-bar" class="w-3.5 h-3.5" />
                      </.link>
                      <button
                        phx-click="edit_overrides"
                        phx-value-id={member.id}
                        class="btn btn-xs btn-ghost"
                        id={"edit-overrides-#{member.id}"}
                        title="Editar extras"
                      >
                        <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                      </button>
                      <button
                        phx-click="replace_key"
                        phx-value-id={member.id}
                        class="btn btn-xs btn-ghost"
                        id={"replace-key-#{member.id}"}
                        title="Regenerar clave"
                        data-confirm="¿Regenerar clave? La clave actual dejará de funcionar inmediatamente."
                      >
                        <.icon name="hero-key" class="w-3.5 h-3.5" />
                      </button>
                      <%= if member.api_key && member.api_key.status == "active" do %>
                        <button
                          phx-click="revoke_key"
                          phx-value-id={member.id}
                          class="btn btn-xs btn-ghost text-error"
                          id={"revoke-key-#{member.id}"}
                          title="Revocar clave"
                          data-confirm="¿Revocar clave? Esta acción no se puede deshacer."
                        >
                          <.icon name="hero-no-symbol" class="w-3.5 h-3.5" />
                        </button>
                      <% end %>
                      <button
                        phx-click="clear_sticky_routes"
                        phx-value-id={member.id}
                        class="btn btn-xs btn-ghost"
                        id={"clear-sticky-#{member.id}"}
                        title="Limpiar sticky routes (fuerza re-ruteo)"
                      >
                        <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
                      </button>
                      <button
                        phx-click="remove_member"
                        phx-value-id={member.id}
                        class="btn btn-xs btn-ghost text-error"
                        id={"remove-#{member.id}"}
                        title="Eliminar miembro"
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" />
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div
            :if={@members_empty?}
            class="text-center py-12 text-base-content/40"
            id="members-empty"
          >
            <.icon name="hero-users" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>Este grupo no tiene miembros todavía.</p>
          </div>
        </div>

        <%!-- Member details modal — modelos + API keys exclusivas --%>
        <div
          :if={@editing_details_member_id}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id={"member-details-#{@editing_details_member_id}"}
        >
          <div class="absolute inset-0 bg-black/50" phx-click="close_details" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <% member = Enum.find(@members, &(&1.id == @editing_details_member_id)) %>
              <div :if={member}>
                <h2 class="text-lg font-semibold mb-1">{member.user.email}</h2>
                <p class="text-xs text-base-content/50 mb-4">{member.user.name}</p>

                <div>
                  <p class="text-xs text-base-content/50 uppercase tracking-wide mb-2">Modelos</p>
                  <p class="text-xs text-base-content/40 mb-2">
                    Los modelos del grupo están otorgados a todos los miembros; los extras son
                    individuales.
                  </p>
                  <.model_picker
                    id={"model-picker-member-#{member.id}"}
                    models={@org_models}
                    granted_ids={MapSet.to_list(@group_alias_ids)}
                    extra_ids={extra_model_ids(@extra_models, member.id)}
                    denied_ids={denied_model_ids(@denied_models, member.id)}
                    toggle_event="toggle_extra_model"
                    target_value={member.id}
                    empty_text="No hay modelos disponibles."
                  />
                </div>

                <div class="mt-4 pt-4 border-t border-base-200">
                  <p class="text-xs text-base-content/50 uppercase tracking-wide mb-2">
                    API Keys Exclusivas
                  </p>
                  <% member_exclusive = Map.get(@exclusive_providers || %{}, member.id, []) %>
                  <%= if member_exclusive == [] do %>
                    <p class="text-xs text-base-content/40">Sin keys exclusivas asignadas.</p>
                  <% else %>
                    <div class="space-y-1">
                      <div
                        :for={mp <- member_exclusive}
                        class="flex items-center justify-between text-xs py-1 px-2 rounded bg-base-200/50"
                      >
                        <div class="flex items-center gap-2 min-w-0">
                          <span class="badge badge-xs badge-warning">exclusiva</span>
                          <span class="font-medium truncate">{mp.model.name}</span>
                          <span class="text-base-content/40">·</span>
                          <span class="text-base-content/50">
                            {if mp.credential && mp.credential.provider,
                              do: mp.credential.provider.name,
                              else: "—"}
                          </span>
                          <span class="text-base-content/40 font-mono">
                            {if mp.credential,
                              do: TokengateWeb.ModelsLive.mask_key(mp.credential.api_key_encrypted),
                              else: "—"}
                          </span>
                        </div>
                        <span class="badge badge-xs badge-ghost">{mp.provider_model}</span>
                      </div>
                    </div>
                  <% end %>
                </div>

                <div class="flex justify-end mt-4">
                  <button
                    type="button"
                    phx-click="close_details"
                    class="btn btn-primary btn-sm"
                    id="close-details-btn"
                  >
                    Cerrar
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
