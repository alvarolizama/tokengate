defmodule TokengateWeb.GroupMembersLive do
  @moduledoc """
  Per-sub member management (antes «grupo», ahora sub mensual).

  Access:
    - admin: manages members of any group.
    - user: denied — redirected to /dashboard.

  Supports:
    - Add member by email.
    - Remove member.
    - Per-member extra model grants (individual grants beyond the sub's
      models) with the 3-state picker in the details modal.

  Las API keys y los extras de concurrencia/RPM NO se gestionan aquí: las keys
  cuelgan del usuario y los límites los aporta la sub (o el propio sujeto en su
  página).
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
          |> assign(:editing_details_member_id, nil)
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

    # Límites EFECTIVOS por miembro — la misma regla única que el proxy usa
    # (`propio del usuario || default del grupo || default del módulo`).
    # `@group` ya está en memoria y `:user` viene preloadeado por
    # `list_group_members_for_group/1`: sin query extra ni N+1.
    member_limits =
      Map.new(members, fn m -> {m.id, Accounts.effective_limits(%{m | group: group})} end)

    socket
    |> assign(:members, members)
    |> assign(:member_limits, member_limits)
    |> assign(:member_budgets, Map.new(member_budgets, fn b -> {b.member_id, b} end))
    |> assign(:members_empty?, members == [])
    |> assign(:org_models, org_alias_ids)
    |> assign(:group_alias_ids, group_alias_ids)
    |> assign(:extra_models, extra_aliases_simple)
    |> assign(:denied_models, denied_models)
    |> assign(:group_monthly_spend, group_monthly_spend)
    |> assign(:usage_tiers, usage_tiers)
  end

  defp days_ago(n) do
    DateTime.add(DateTime.utc_now(), -n * 86400, :second)
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
         {:ok, user} <- fetch_user_by_email(email) do
      attrs = %{user_id: user.id, group_id: group.id}

      case Accounts.create_group_member(attrs) do
        {:ok, _member} ->
          {:noreply,
           socket
           |> put_flash(:info, "Miembro añadido.")
           |> assign(:show_add_modal?, false)
           |> assign(:add_form, add_member_form())
           |> assign(:add_member_error, nil)
           |> load_data()}

        {:error, changeset} ->
          {:noreply,
           socket
           |> assign(:add_member_error, format_add_member_error(changeset))
           |> assign(:add_form, to_form(params, as: :add_member))}
      end
    else
      :error ->
        {:noreply,
         socket
         |> assign(:add_member_error, "Escribe el email del usuario.")
         |> assign(:add_form, to_form(params, as: :add_member))}

      nil ->
        {:noreply,
         socket
         |> assign(:add_member_error, "No existe un usuario con ese email.")
         |> assign(:add_form, to_form(params, as: :add_member))}
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

  ## Events — details modal (modelos del miembro) ---------------------------

  @impl true
  def handle_event("open_details", %{"id" => member_id}, socket) do
    {:noreply, assign(socket, :editing_details_member_id, member_id)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, :editing_details_member_id, nil)}
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

  defp add_member_form do
    to_form(%{"email" => ""}, as: :add_member)
  end

  # La invariante «un usuario = una sub» sale como error de índice único en
  # `user_id`; se traduce a algo accionable en vez del críptico "has already
  # been taken".
  defp format_add_member_error(changeset) do
    if Keyword.has_key?(changeset.errors, :user_id) do
      "Ese usuario ya pertenece a otra sub mensual. Quítalo de ella primero."
    else
      format_changeset_errors(changeset)
    end
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
          <:subtitle>Añade y quita miembros de la sub</:subtitle>
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
                </div>
                <%!-- Un usuario pertenece a UNA sola sub mensual, así que sólo
                     puede estar en una: si ya tiene otra, el alta falla. --%>
                <p class="text-xs text-base-content/50 mt-3">
                  Cada usuario pertenece a una sola sub mensual. Si ya tiene otra, quítalo
                  de ella primero.
                </p>
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
                  <% limits = Map.fetch!(@member_limits, member.id) %>
                  <% own_conc? = not is_nil(member.user.default_concurrency_limit) %>
                  <% own_rpm? = not is_nil(member.user.default_rpm_limit) %>
                  <td>
                    <p class="font-medium text-sm">{member.user.email}</p>
                    <p class="text-xs text-base-content/50">{member.user.name}</p>
                    <div class="flex items-center gap-1.5 mt-1 flex-wrap">
                      <span class="badge badge-xs badge-ghost capitalize">{member.status}</span>
                    </div>
                  </td>
                  <td class="text-xs whitespace-nowrap" id={"limits-#{member.id}"}>
                    <p class="flex items-center gap-1">
                      <span class="text-base-content/50">Conc.</span>
                      {limits.concurrency_limit}
                      <span
                        :if={own_conc?}
                        class="badge badge-xs badge-accent"
                        title="Override propio del usuario sobre el default del grupo"
                      >
                        propio
                      </span>
                    </p>
                    <p class="flex items-center gap-1">
                      <span class="text-base-content/50">RPM</span>
                      {limits.rpm_limit}
                      <span
                        :if={own_rpm?}
                        class="badge badge-xs badge-accent"
                        title="Override propio del usuario sobre el default del grupo"
                      >
                        propio
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
                        title="Modelos del miembro"
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

        <%!-- Member details modal — modelos --%>
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
