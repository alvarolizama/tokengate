defmodule TokengateWeb.GroupMembersLive do
  @moduledoc """
  Per-limit-profile member management (vocabulario de UI: «perfil de límites»).

  Access:
    - admin: manages members of any group.
    - user: denied — redirected to /dashboard.

  Supports:
    - Add member by email.
    - Remove member.
    - Per-member extra model grants (individual grants beyond the budget's
      models) with the 3-state picker in the details modal.

  Las API keys y los extras de concurrencia/RPM NO se gestionan aquí: las keys
  cuelgan del usuario y el techo lo aporta el perfil de límites (o el propio sujeto en su
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

    case fetch_group(group_id) do
      nil ->
        # A non-UUID or a deleted profile must not raise: empty state + back
        # to the list, never a dead LiveView.
        {:ok,
         socket
         |> put_flash(:error, gettext("Limit profile not found."))
         |> redirect(to: "/budget/profiles")}

      group ->
        mount_group(socket, user, group)
    end
  end

  defp mount_group(socket, user, group) do
    case check_access(user, group) do
      :ok ->
        socket =
          socket
          |> assign(:page_title, gettext("Members") <> " · Tokengate")
          |> assign(:group, group)
          |> assign(:editing_details_member_id, nil)
          |> assign(:show_add_modal?, false)
          |> assign(:add_form, add_member_form())
          |> assign(:add_member_error, nil)
          |> assign(:email_suggestions, [])
          |> stream_configure(:members, dom_id: &"members-#{&1.id}")
          |> load_data()
          |> load_usage_tiers()

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
    {:denied, gettext("You do not have permission to manage this limit profile.")}
  end

  ## Data loading ---------------------------------------------------------

  defp load_data(socket) do
    group = socket.assigns.group
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    members = Accounts.list_group_members_for_group(group.id)

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

    # Límites EFECTIVOS por miembro — la misma regla única que el proxy usa
    # (`propio del usuario || default del perfil de límites || default del módulo`).
    # `@group` ya está en memoria y `:user` viene preloadeado por
    # `list_group_members_for_group/1`: sin query extra ni N+1.
    member_limits =
      Map.new(members, fn m -> {m.id, Accounts.effective_limits(%{m | group: group})} end)

    socket
    |> stream(:members, members, reset: true)
    # The details modal needs one row by id; streams are not enumerable, so the
    # lookup lives in its own map instead of an Enum.find over the stream.
    |> assign(:members_by_id, Map.new(members, &{&1.id, &1}))
    |> assign(:member_limits, member_limits)
    |> assign(:member_budgets, Map.new(member_budgets, fn b -> {b.member_id, b} end))
    |> assign(:members_empty?, members == [])
    |> assign(:org_models, org_alias_ids)
    |> assign(:group_alias_ids, group_alias_ids)
    |> assign(:extra_models, extra_aliases_simple)
    |> assign(:denied_models, denied_models)
    |> assign(:group_monthly_spend, group_monthly_spend)
  end

  # Usage tiers for this group (last 30 days). The heaviest aggregate of
  # the page (member × minute buckets over 30 days) — NOT on the search
  # path: `search_members` re-filters the member list but cannot change
  # the tiers, so this runs on mount and when the membership set actually
  # changes (add/remove member).
  defp load_usage_tiers(socket) do
    group = socket.assigns.group

    usage_tiers = Rollup.member_usage_tiers(group.id, from: days_ago(30))

    assign(socket, :usage_tiers, usage_tiers)
  end

  defp days_ago(n) do
    DateTime.add(DateTime.utc_now(), -n * 86400, :second)
  end

  ## Events — add member --------------------------------------------------

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
        {:ok, member} ->
          audit(socket, "group_member.add", "group_member", member.id, %{
            "group_id" => group.id,
            "user_id" => user.id,
            "email" => user.email
          })

          {:noreply,
           socket
           |> put_flash(:info, gettext("Member added."))
           |> assign(:show_add_modal?, false)
           |> assign(:add_form, add_member_form())
           |> assign(:add_member_error, nil)
           |> load_data()
           |> load_usage_tiers()}

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
         |> assign(:add_member_error, gettext("Type the user email."))
         |> assign(:add_form, to_form(params, as: :add_member))}

      nil ->
        {:noreply,
         socket
         |> assign(:add_member_error, gettext("No user with that email exists."))
         |> assign(:add_form, to_form(params, as: :add_member))}
    end
  end

  ## Events — remove member ----------------------------------------------

  @impl true
  def handle_event("remove_member", %{"id" => member_id}, socket) do
    case fetch_group_member(member_id) do
      {:ok, member} ->
        remove_member(socket, member)

      :error ->
        {:noreply,
         put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}
    end
  end

  ## Events — details modal (modelos del miembro) ---------------------------

  @impl true
  def handle_event("open_details", %{"id" => member_id}, socket) do
    case fetch_group_member(member_id) do
      {:ok, %{group_id: group_id} = member} when group_id == socket.assigns.group.id ->
        {:noreply, assign(socket, :editing_details_member_id, member.id)}

      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}
    end
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
    case fetch_group_member(member_id) do
      {:ok, member} ->
        toggle_extra_model(socket, member, model_id)

      :error ->
        {:noreply,
         put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}
    end
  end

  # Catch-all: an event with an unexpected payload (or from a stale client)
  # leaves the socket untouched instead of raising FunctionClauseError and
  # killing the LiveView.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Helpers --------------------------------------------------------------

  # A client-supplied id reaches `Repo.get` as a string: a non-UUID would raise
  # `Ecto.Query.CastError` and kill the LiveView, so it is cast first.
  defp fetch_group(group_id) do
    with {:ok, group_id} <- Ecto.UUID.cast(group_id) do
      Accounts.get_group(group_id)
    else
      _ -> nil
    end
  end

  defp fetch_group_member(member_id) do
    with {:ok, member_id} <- Ecto.UUID.cast(member_id),
         %{} = member <- Accounts.get_group_member(member_id) do
      {:ok, member}
    else
      _ -> :error
    end
  end

  # Body of `remove_member`: the row must belong to THIS profile.
  defp remove_member(socket, member) do
    if member.group_id != socket.assigns.group.id do
      {:noreply,
       put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}
    else
      case Accounts.delete_group_member(member) do
        {:ok, _} ->
          audit(socket, "group_member.remove", "group_member", member.id, %{
            "group_id" => member.group_id,
            "user_id" => member.user_id
          })

          {:noreply,
           socket
           |> put_flash(:info, gettext("Member removed."))
           |> load_data()
           |> load_usage_tiers()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not remove the member."))}
      end
    end
  end

  # Body of `toggle_extra_model` (picker de 3 estados) for a member of THIS
  # profile.
  defp toggle_extra_model(socket, member, model_id) do
    member_id = member.id

    if member.group_id != socket.assigns.group.id do
      {:noreply,
       put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}
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
          audit(socket, "group_member.model_access_change", "group_member", member_id, %{
            "model_id" => model_id
          })

          {:noreply,
           socket
           |> put_flash(:info, "Modelos actualizados.")
           |> load_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
      end
    end
  end

  defp add_member_form do
    to_form(%{"email" => ""}, as: :add_member)
  end

  # La invariante «un usuario = un presupuesto» sale como error de índice único en
  # `user_id`; se traduce a algo accionable en vez del críptico "has already
  # been taken".
  defp format_add_member_error(changeset) do
    if Keyword.has_key?(changeset.errors, :user_id) do
      gettext("That user already belongs to another limit profile. Remove them from it first.")
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
          <:subtitle>{gettext("Add and remove limit profile members")}</:subtitle>
          <:actions>
            <.link navigate={~p"/budget/profiles"} class="btn btn-ghost" id="back-to-groups">
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
        <.modal
          :if={@show_add_modal?}
          id="add-member-modal"
          title={gettext("Add member")}
          on_close="cancel_add_member"
          max_w="max-w-2xl"
        >
          <.form for={@add_form} id="add-member-form" phx-submit="add_member">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <%!-- Email input with live autocomplete --%>
              <div class="sm:col-span-2 relative">
                <.input
                  field={@add_form[:email]}
                  type="email"
                  label={gettext("User email")}
                  placeholder={gettext("user@example.com")}
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
            <%!-- Un usuario pertenece a UN solo presupuesto mensual, así que sólo
                 puede estar en una: si ya tiene otra, el alta falla. --%>
            <p class="text-xs text-base-content/50 mt-3">
              {gettext(
                "Each user belongs to a single limit profile. If they already have another, remove them"
              )}
              {gettext("from it first.")}
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
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary btn-sm" id="add-member-btn-submit">
                {gettext("Add")}
              </button>
            </div>
          </.form>
        </.modal>

        <%!-- Resumen del perfil de límites — fila compacta --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="group-config">
          <div class="card-body p-4">
            <div class="flex flex-wrap items-center gap-x-8 gap-y-3">
              <div>
                <p class="text-[10px] uppercase tracking-wide text-base-content/40">
                  {gettext("Concurrency")}
                </p>
                <p class="text-lg font-bold">{@group.default_concurrency_limit}</p>
                <p class="text-xs text-base-content/40">{gettext("per user")}</p>
              </div>
              <div>
                <p class="text-[10px] uppercase tracking-wide text-base-content/40">RPM</p>
                <p class="text-lg font-bold">{@group.default_rpm_limit}</p>
                <p class="text-xs text-base-content/40">{gettext("per user")}</p>
              </div>
              <div>
                <p class="text-[10px] uppercase tracking-wide text-base-content/40">
                  {gettext("Spend/month")}
                </p>
                <p class="text-lg font-bold text-success">${format_decimal(@group_monthly_spend)}</p>
                <p class="text-xs text-base-content/40">{gettext("current")}</p>
              </div>
            </div>
          </div>
        </div>

        <div id="members">
          <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
            <.table
              id="members-rows"
              rows={@streams.members}
              row_item={fn {_id, member} -> member end}
              row_class="align-top"
              empty?={@members_empty?}
            >
              <:col :let={member} label={gettext("Member")}>
                <p class="font-medium text-sm">{member.user.email}</p>
                <p class="text-xs text-base-content/50">{member.user.name}</p>
                <div class="flex items-center gap-1.5 mt-1 flex-wrap">
                  <span class="badge badge-xs badge-ghost capitalize">{member.status}</span>
                </div>
              </:col>
              <:col :let={member} label={gettext("Limits")}>
                <% limits = Map.fetch!(@member_limits, member.id) %>
                <div id={"limits-#{member.id}"} class="text-xs whitespace-nowrap">
                  <p class="flex items-center gap-1">
                    <span class="text-base-content/50">Conc.</span>
                    {limits.concurrency_limit}
                    <span
                      :if={not is_nil(member.user.default_concurrency_limit)}
                      class="badge badge-xs badge-accent"
                      title={gettext("The user's own override over the limit profile default")}
                    >
                      propio
                    </span>
                  </p>
                  <p class="flex items-center gap-1">
                    <span class="text-base-content/50">RPM</span>
                    {limits.rpm_limit}
                    <span
                      :if={not is_nil(member.user.default_rpm_limit)}
                      class="badge badge-xs badge-accent"
                      title={gettext("The user's own override over the limit profile default")}
                    >
                      propio
                    </span>
                  </p>
                </div>
              </:col>
              <:col :let={member} label={gettext("Models")}>
                <div class="flex items-center gap-1.5 flex-wrap">
                  <button
                    phx-click="open_details"
                    phx-value-id={member.id}
                    class="badge badge-sm badge-outline gap-1 hover:badge-primary cursor-pointer transition-colors"
                    id={"details-#{member.id}"}
                    title={gettext("Member models")}
                  >
                    <.icon name="hero-rectangle-stack" class="w-3 h-3" />
                    {length(MapSet.to_list(@group_alias_ids))} del perfil de límites
                  </button>
                  <span
                    :if={extra_model_ids(@extra_models, member.id) != []}
                    class="badge badge-sm badge-accent"
                  >
                    +{length(extra_model_ids(@extra_models, member.id))} extra
                  </span>
                </div>
              </:col>
              <:col :let={member} label={gettext("Spend/month")} align="right">
                <% mb = Map.get(@member_budgets, member.id, %{monthly_spend: Decimal.new(0)}) %>
                <span class="font-mono text-sm">${format_decimal(mb.monthly_spend)}</span>
              </:col>
              <:col :let={member} label={gettext("Usage")}>
                <% tier = get_member_tier(@usage_tiers, member.id) %>
                <%= if tier do %>
                  <span
                    class={["badge badge-sm", tier_badge_class(tier.tier)]}
                    title={
                      gettext(
                        "Score: %{score} | Peak RPM: %{peak_rpm} | Active days: %{active_days} | Requests: %{requests}",
                        score: tier.score,
                        peak_rpm: tier.peak_rpm,
                        active_days: tier.active_days,
                        requests: tier.request_count
                      )
                    }
                  >
                    {String.capitalize(tier.tier)}
                  </span>
                <% else %>
                  <span class="badge badge-sm badge-ghost" title={gettext("No activity in 30 days")}>—</span>
                <% end %>
              </:col>
              <:action :let={member}>
                <.link
                  navigate={~p"/stats/users/#{member.user_id}"}
                  class="btn btn-xs btn-ghost"
                  id={"stats-#{member.id}"}
                  title={gettext("View this user's consolidated stats")}
                >
                  <.icon name="hero-chart-bar" class="w-3.5 h-3.5" />
                </.link>
                <button
                  phx-click="remove_member"
                  phx-value-id={member.id}
                  class="btn btn-xs btn-ghost text-error"
                  id={"remove-#{member.id}"}
                  title={gettext("Remove member")}
                >
                  <.icon name="hero-trash" class="w-3.5 h-3.5" />
                </button>
              </:action>
              <:empty>
                <div id="members-empty">
                  <.icon name="hero-users" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                  <p>{gettext("This limit profile has no members yet.")}</p>
                </div>
              </:empty>
            </.table>
          </div>
        </div>

        <%!-- Member details modal — modelos --%>
        <% member = Map.get(@members_by_id, @editing_details_member_id) %>
        <.modal
          :if={member}
          id={"member-details-#{@editing_details_member_id}"}
          title={member.user.email}
          on_close="close_details"
        >
          <p class="text-xs text-base-content/50 mb-4">{member.user.name}</p>

          <div>
            <p class="text-xs text-base-content/50 uppercase tracking-wide mb-2">
              {gettext("Models")}
            </p>
            <p class="text-xs text-base-content/40 mb-2">
              {gettext("The limit profile models are granted to every member; the extras are")}
              {gettext("per member.")}
            </p>
            <.model_picker
              id={"model-picker-member-#{member.id}"}
              models={@org_models}
              granted_ids={MapSet.to_list(@group_alias_ids)}
              extra_ids={extra_model_ids(@extra_models, member.id)}
              denied_ids={denied_model_ids(@denied_models, member.id)}
              toggle_event="toggle_extra_model"
              target_value={member.id}
            />
          </div>

          <:footer>
            <button
              type="button"
              phx-click="close_details"
              class="btn btn-primary btn-sm"
              id="close-details-btn"
            >
              {gettext("Close")}
            </button>
          </:footer>
        </.modal>
      </div>
    </Layouts.dashboard>
    """
  end
end
