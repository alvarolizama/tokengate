defmodule TokengateWeb.GroupMembersLive do
  @moduledoc """
  Per-limit-profile member management (vocabulario de UI: «perfil de límites»).

  Access:
    - admin: manages members of any group.
    - user: denied — redirected to /dashboard.

  Supports:
    - DB-backed search, sorting, and pagination via `Accounts.list_group_members_page/2`.
    - Add member by email.
    - Remove member (with `data-confirm`).
    - Per-member extra/denied model grants (3-state picker in the details modal).
    - Async 30-day usage tiers via `start_async` + `DashboardCache`.

  Las API keys y los extras de concurrencia/RPM NO se gestionan aquí: las keys
  cuelgan del usuario y el techo lo aporta el perfil de límites (o el propio sujeto en su
  página).
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  import TokengateWeb.AdminComponents
  alias Tokengate.Accounts
  alias Tokengate.Credits
  alias Tokengate.Metrics.{DashboardCache, Rollup}
  alias Tokengate.Providers
  alias Tokengate.Providers.{Model, GroupMemberExtraModel, GroupMemberDeniedModel, GroupModel}
  alias Tokengate.Repo
  alias TokengateWeb.StatsHelpers, as: Stats

  @per_page 30
  @sort_columns ~w(email name status spend inserted_at)a
  @usage_tiers_ttl_ms 30_000

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
          |> assign(:search_query, "")
          |> assign(:sort_field, :email)
          |> assign(:sort_direction, :asc)
          |> assign(:page, 1)
          |> assign(:per_page, @per_page)
          |> assign(:total_count, 0)
          |> assign(:total_pages, 1)
          |> assign(:current_members, [])
          |> stream_configure(:members, dom_id: &"members-#{&1.id}")
          |> assign(:usage_tiers, [])
          |> assign(:usage_tiers_by_member, %{})
          |> assign(:usage_tiers_loading, false)
          |> load_data()
          |> maybe_load_usage_tiers()

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

    page =
      Accounts.list_group_members_page(
        group.id,
        search: socket.assigns[:search_query] || "",
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        sort_field: socket.assigns.sort_field,
        sort_direction: socket.assigns.sort_direction
      )

    members = page.entries
    member_ids = Enum.map(members, & &1.id)
    all_member_ids = Accounts.list_member_ids_for_group(group.id)

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

    # Preload extra model ids ONLY for the active page's member IDs
    extra_aliases_simple =
      if member_ids == [] do
        %{}
      else
        from(tmea in GroupMemberExtraModel,
          where: tmea.group_member_id in ^member_ids,
          select: {tmea.group_member_id, tmea.model_id}
        )
        |> Repo.all()
        |> Enum.group_by(fn {tm_id, _} -> tm_id end, fn {_, model_id} -> model_id end)
      end

    # Per-member denied model ids ONLY for the active page's member IDs
    denied_models =
      if member_ids == [] do
        %{}
      else
        from(tmda in GroupMemberDeniedModel,
          where: tmda.group_member_id in ^member_ids,
          select: {tmda.group_member_id, tmda.model_id}
        )
        |> Repo.all()
        |> Enum.group_by(fn {tm_id, _} -> tm_id end, fn {_, model_id} -> model_id end)
      end

    # Gasto mensual UTC real de TODO el perfil de límites (no sólo la página visible).
    all_monthly_spend = Tokengate.Budgets.monthly_spend_by_member_ids(all_member_ids)

    member_budgets =
      Map.new(members, fn m ->
        {m.id,
         %{
           member_id: m.id,
           monthly_spend: Map.get(all_monthly_spend, m.id, Decimal.new(0))
         }}
      end)

    group_monthly_spend =
      Enum.reduce(all_monthly_spend, Decimal.new(0), fn {_id, spend}, acc ->
        Decimal.add(acc, spend)
      end)

    member_credits = Credits.summaries(members, cached: true)

    # Límites EFECTIVOS por miembro — la misma regla única que el proxy usa
    # (`propio del usuario || default del perfil de límites || default del módulo`).
    member_limits =
      Map.new(members, fn m -> {m.id, Accounts.effective_limits(%{m | group: group})} end)

    sorted_members =
      if socket.assigns.sort_field in Accounts.group_member_page_sql_sorts() do
        members
      else
        sort_members_in_memory(
          members,
          socket.assigns.sort_field,
          socket.assigns.sort_direction,
          member_budgets
        )
      end

    socket
    |> assign(:current_members, sorted_members)
    |> stream(:members, sorted_members, reset: true)
    # The details modal needs one row by id; streams are not enumerable, so the
    # lookup lives in its own map instead of an Enum.find over the stream.
    |> assign(:members_by_id, Map.new(sorted_members, &{&1.id, &1}))
    |> assign(:member_limits, member_limits)
    |> assign(:member_budgets, member_budgets)
    |> assign(:member_credits, member_credits)
    |> assign(:group_total_members, length(all_member_ids))
    |> assign(:members_empty?, page.total == 0)
    |> assign(:page, page.page)
    |> assign(:total_count, page.total)
    |> assign(:total_pages, page.total_pages)
    |> assign(:org_models, org_alias_ids)
    |> assign(:group_alias_ids, group_alias_ids)
    |> assign(:extra_models, extra_aliases_simple)
    |> assign(:denied_models, denied_models)
    |> assign(:group_monthly_spend, group_monthly_spend)
  end

  defp sort_members_in_memory(members, :spend, direction, member_budgets) do
    Enum.sort_by(
      members,
      fn m ->
        spend =
          member_budgets
          |> Map.get(m.id, %{monthly_spend: Decimal.new(0)})
          |> Map.get(:monthly_spend, Decimal.new(0))

        {spend, String.downcase(m.user.email || "")}
      end,
      fn {spend_a, email_a}, {spend_b, email_b} ->
        case {Decimal.compare(spend_a, spend_b), direction} do
          {:eq, _} -> email_a <= email_b
          {:lt, :asc} -> true
          {:gt, :desc} -> true
          _ -> false
        end
      end
    )
  end

  defp sort_members_in_memory(members, _field, _direction, _member_budgets), do: members

  # Usage tiers for this group (last 30 days). Dispatched asynchronously via
  # `start_async/3` + `DashboardCache` so `mount` never blocks on the heavy
  # 30d rollup query.
  defp maybe_load_usage_tiers(socket) do
    group_id = socket.assigns.group.id
    cache_key = usage_tiers_cache_key(group_id)

    case cached_usage_tiers_fetch(cache_key) do
      {:ok, usage_tiers} ->
        apply_usage_tiers(socket, usage_tiers)

      :miss ->
        if connected?(socket) do
          use_cache? = structural_cache_enabled?() and DashboardCache.available?()

          socket
          |> assign(:usage_tiers_loading, true)
          |> start_async(:usage_tiers, fn ->
            compute = fn -> Rollup.member_usage_tiers(group_id, from: days_ago(30)) end

            if use_cache? do
              DashboardCache.fetch_or_compute(cache_key, compute, ttl: @usage_tiers_ttl_ms)
            else
              compute.()
            end
          end)
        else
          socket
        end
    end
  end

  defp usage_tiers_cache_key(group_id), do: {:group_member_usage_tiers, group_id}

  defp structural_cache_enabled? do
    Application.get_env(:tokengate, :stats_structural_cache, enabled: true)[:enabled] != false
  end

  defp cached_usage_tiers_fetch(key) do
    if structural_cache_enabled?() and DashboardCache.available?() do
      DashboardCache.fetch(key)
    else
      :miss
    end
  end

  defp invalidate_usage_tiers_cache(group_id) do
    if DashboardCache.available?() do
      DashboardCache.invalidate(usage_tiers_cache_key(group_id))
    end
  end

  defp apply_usage_tiers(socket, usage_tiers) do
    socket
    |> assign(:usage_tiers, usage_tiers)
    |> assign(:usage_tiers_by_member, Map.new(usage_tiers, &{&1.group_member_id, &1}))
  end

  @impl true
  def handle_async(:usage_tiers, {:ok, usage_tiers}, socket) do
    {:noreply,
     socket
     |> apply_usage_tiers(usage_tiers)
     |> assign(:usage_tiers_loading, false)
     |> stream(:members, socket.assigns.current_members, reset: true)}
  end

  def handle_async(:usage_tiers, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :usage_tiers_loading, false)}
  end

  defp days_ago(n) do
    DateTime.add(DateTime.utc_now(), -n * 86400, :second)
  end

  ## Events — search / sort / pagination -----------------------------------

  @impl true
  def handle_event("search_members", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 1)
     |> load_data()}
  end

  def handle_event("go_to_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:page, parse_page(page))
     |> load_data()}
  end

  def handle_event("sort_members", %{"field" => field}, socket) do
    with {:ok, field} <- to_sort_field(field),
         true <- field in @sort_columns do
      {sort_field, sort_direction} =
        if socket.assigns.sort_field == field do
          {field, toggle_sort_direction(socket.assigns.sort_direction)}
        else
          {field, default_direction_for(field)}
        end

      {:noreply,
       socket
       |> assign(:sort_field, sort_field)
       |> assign(:sort_direction, sort_direction)
       |> assign(:page, 1)
       |> load_data()}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Events — add member --------------------------------------------------

  def handle_event("new_member", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal?, true)
     |> assign(:add_form, add_member_form())
     |> assign(:add_member_error, nil)}
  end

  def handle_event("cancel_add_member", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal?, false)
     |> assign(:add_form, add_member_form())
     |> assign(:add_member_error, nil)
     |> assign(:email_suggestions, [])}
  end

  def handle_event("search_email", %{"add_member" => %{"email" => query}}, socket) do
    suggestions =
      case String.trim(query) do
        "" -> []
        trimmed when byte_size(trimmed) < 2 -> []
        trimmed -> Accounts.search_users(trimmed)
      end

    {:noreply, assign(socket, :email_suggestions, suggestions)}
  end

  def handle_event("select_email", %{"email" => email}, socket) do
    form =
      socket.assigns.add_form
      |> Map.update!(:params, fn params -> Map.put(params, "email", email) end)

    {:noreply,
     socket
     |> assign(:add_form, to_form(form.params, as: :add_member))
     |> assign(:email_suggestions, [])}
  end

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

          invalidate_usage_tiers_cache(group.id)

          {:noreply,
           socket
           |> put_flash(:info, gettext("Member added."))
           |> assign(:show_add_modal?, false)
           |> assign(:add_form, add_member_form())
           |> assign(:add_member_error, nil)
           |> load_data()
           |> maybe_load_usage_tiers()}

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

  def handle_event("open_details", %{"id" => member_id}, socket) do
    case fetch_group_member(member_id) do
      {:ok, %{group_id: group_id} = member} when group_id == socket.assigns.group.id ->
        {:noreply, assign(socket, :editing_details_member_id, member.id)}

      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}
    end
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, :editing_details_member_id, nil)}
  end

  ## Events — acceso SmartRouter del miembro (tri-estado) -------------------

  def handle_event("set_router_access", %{"id" => member_id, "state" => state}, socket) do
    case fetch_group_member(member_id) do
      {:ok, member} ->
        set_router_access(socket, member, state)

      :error ->
        {:noreply,
         put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}
    end
  end

  ## Events — extra model grants / denies (picker de 3 estados) ------------

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

          invalidate_usage_tiers_cache(member.group_id)

          {:noreply,
           socket
           |> put_flash(:info, gettext("Member removed."))
           |> load_data()
           |> maybe_load_usage_tiers()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not remove the member."))}
      end
    end
  end

  # Body of `toggle_extra_model` (picker de 3 estados) for a member of THIS
  # profile.
  defp toggle_extra_model(socket, member, model_id) do
    member_id = member.id

    with :ok <- if(member.group_id == socket.assigns.group.id, do: :ok, else: :wrong_group),
         {:ok, model_uuid} <- Ecto.UUID.cast(model_id) do
      existing = Map.get(socket.assigns.extra_models, member_id, [])
      denied = Map.get(socket.assigns.denied_models, member_id, [])
      inherited? = MapSet.member?(socket.assigns.group_alias_ids, model_uuid)

      result =
        cond do
          # Estado "quitado" → permitir de nuevo (borra el deny).
          model_uuid in denied ->
            Providers.allow_model(member_id, model_uuid)

          # Estado "heredado" del perfil → denegar en 1 click (y limpiar extra
          # residual si existía, para que al quitar el deny no resucite).
          inherited? ->
            with {:ok, _} = ok <- Providers.deny_model(member_id, model_uuid) do
              if model_uuid in existing,
                do: Providers.revoke_extra_model(member_id, model_uuid),
                else: ok
            end

          # Estado "agregado" (extra propio, no heredado) → revocar el extra
          # sin crear fila en denied.
          model_uuid in existing ->
            Providers.revoke_extra_model(member_id, model_uuid)

          # Estado "sin acceso" → agregar como extra.
          true ->
            Providers.grant_extra_model(member_id, model_uuid)
        end

      case result do
        {:ok, _} ->
          audit(socket, "group_member.model_access_change", "group_member", member_id, %{
            "model_id" => model_uuid
          })

          {:noreply,
           socket
           |> put_flash(:info, gettext("Models updated."))
           |> refresh_member_model_overrides(member_id)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
      end
    else
      :wrong_group ->
        {:noreply,
         put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
    end
  end

  defp refresh_member_model_overrides(socket, updated_member_id) do
    member_ids = Map.keys(socket.assigns.members_by_id)

    extra_models =
      if member_ids == [] do
        %{}
      else
        from(tmea in GroupMemberExtraModel,
          where: tmea.group_member_id in ^member_ids,
          select: {tmea.group_member_id, tmea.model_id}
        )
        |> Repo.all()
        |> Enum.group_by(fn {tm_id, _} -> tm_id end, fn {_, model_id} -> model_id end)
      end

    denied_models =
      if member_ids == [] do
        %{}
      else
        from(tmda in GroupMemberDeniedModel,
          where: tmda.group_member_id in ^member_ids,
          select: {tmda.group_member_id, tmda.model_id}
        )
        |> Repo.all()
        |> Enum.group_by(fn {tm_id, _} -> tm_id end, fn {_, model_id} -> model_id end)
      end

    socket =
      socket
      |> assign(:extra_models, extra_models)
      |> assign(:denied_models, denied_models)

    case Map.get(socket.assigns.members_by_id, updated_member_id) do
      nil -> socket
      member -> stream_insert(socket, :members, member)
    end
  end

  defp add_member_form do
    to_form(%{"email" => ""}, as: :add_member)
  end

  ## Helpers — SmartRouter access del miembro ------------------------------

  # Tri-estado: nil = hereda el perfil · true = permite · false = niega.
  # Pintarlo es lo único que hace este helper; el resolutor real (lo que el
  # proxy aplica) sigue siendo `Accounts.router_enabled?/1`.
  defp router_state(%{router_enabled: nil}), do: :inherit
  defp router_state(%{router_enabled: true}), do: :allow
  defp router_state(%{router_enabled: false}), do: :deny

  defp router_state_label(:inherit), do: gettext("Inherited")
  defp router_state_label(:allow), do: gettext("Allowed")
  defp router_state_label(:deny), do: gettext("Denied")

  defp router_state_badge_class(:inherit), do: "badge-ghost"
  defp router_state_badge_class(:allow), do: "badge-success"
  defp router_state_badge_class(:deny), do: "badge-error"

  defp router_effective?(member, group) do
    case member.router_enabled do
      nil -> group.router_enabled == true
      flag -> flag
    end
  end

  defp router_effective_label(true), do: gettext("allowed")
  defp router_effective_label(false), do: gettext("denied")

  defp router_source_label(%{router_enabled: nil}), do: gettext("from the limit profile")

  defp router_source_label(_member), do: gettext("own override")

  defp parse_router_state("inherit"), do: {:ok, nil}
  defp parse_router_state("allow"), do: {:ok, true}
  defp parse_router_state("deny"), do: {:ok, false}
  defp parse_router_state(_state), do: :error

  defp set_router_access(socket, member, state) do
    group = socket.assigns.group

    with {:ok, value} <- parse_router_state(state),
         :ok <- router_member_of_group?(member, group),
         {:ok, updated} <- Accounts.update_group_member(member, %{router_enabled: value}) do
      audit(socket, "group_member.router_access_change", "group_member", member.id, %{
        "group_id" => member.group_id,
        "router_enabled" => value,
        "effective" => router_effective?(updated, group)
      })

      {:noreply,
       socket
       |> put_flash(:info, gettext("Router access updated."))
       |> refresh_member_router_access(updated)}
    else
      :wrong_group ->
        {:noreply,
         put_flash(socket, :error, gettext("The member does not belong to this limit profile."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the router access."))}
    end
  end

  defp router_member_of_group?(member, group) do
    if member.group_id == group.id, do: :ok, else: :wrong_group
  end

  # El miembro editado vuelve al stream y al mapa del modal: la fila y el
  # badge efectivo cambian en el mismo render, sin recargar la página. Se
  # parte del struct ya cargado porque `update_group_member/2` devuelve el
  # miembro sin `user`/`group` precargados y la fila los pinta.
  defp refresh_member_router_access(socket, updated) do
    case Map.get(socket.assigns.members_by_id, updated.id) do
      nil ->
        socket

      loaded ->
        member = %{loaded | router_enabled: updated.router_enabled}

        current_members =
          Enum.map(socket.assigns.current_members, fn row ->
            if row.id == member.id, do: member, else: row
          end)

        socket
        |> assign(:current_members, current_members)
        |> assign(:members_by_id, Map.put(socket.assigns.members_by_id, member.id, member))
        |> stream_insert(:members, member)
    end
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

  defp to_sort_field(field) when is_binary(field) do
    {:ok, String.to_existing_atom(field)}
  rescue
    ArgumentError -> :error
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {i, ""} when i > 0 -> i
      _ -> 1
    end
  end

  defp parse_page(page) when is_integer(page) and page > 0, do: page
  defp parse_page(_), do: 1

  defp toggle_sort_direction(:asc), do: :desc
  defp toggle_sort_direction(:desc), do: :asc

  defp default_direction_for(field) when field in [:spend, :inserted_at], do: :desc
  defp default_direction_for(_), do: :asc

  defp extra_model_ids(extra_models, member_id) do
    Map.get(extra_models, member_id, [])
  end

  defp denied_model_ids(denied_models, member_id) do
    Map.get(denied_models, member_id, [])
  end

  defp format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  defp format_decimal(nil), do: "—"
  defp format_decimal(value), do: to_string(value)

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
          {gettext("Members of %{name}", name: @group.name)}
          <:subtitle>{gettext("Add and remove limit profile members")}</:subtitle>
          <:actions>
            <div class="flex flex-wrap items-center gap-3">
              <.admin_search
                event="search_members"
                value={@search_query}
                placeholder={gettext("Search by email or name…")}
                input_id="member-search"
              />
              <.button phx-click="new_member" id="new-member-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add member")}
              </.button>
              <.link
                navigate={~p"/budget/profiles"}
                class="btn btn-ghost btn-sm"
                id="back-to-groups"
              >
                <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back")}
              </.link>
            </div>
          </:actions>
        </.header>

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
            <div class="flex flex-wrap items-center justify-between gap-4">
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
                <div id="group-config-cap">
                  <p class="text-[10px] uppercase tracking-wide text-base-content/40">
                    {gettext("Monthly cap")}
                  </p>
                  <%= cond do %>
                    <% @group.unlimited_spend -> %>
                      <p class="text-lg font-bold text-success">{gettext("Unlimited")}</p>
                      <p class="text-xs text-base-content/40">{gettext("no monthly ceiling")}</p>
                    <% not is_nil(@group.monthly_spend_limit_usd) -> %>
                      <p class="text-lg font-bold">
                        ${format_decimal(@group.monthly_spend_limit_usd)}
                      </p>
                      <p class="text-xs text-base-content/40">{gettext("per user")}</p>
                    <% true -> %>
                      <p class="text-lg font-bold text-warning">{gettext("No budget")}</p>
                      <p class="text-xs text-base-content/40">{gettext("top-ups only")}</p>
                  <% end %>
                </div>
                <div>
                  <p class="text-[10px] uppercase tracking-wide text-base-content/40">
                    {gettext("Members")}
                  </p>
                  <p class="text-lg font-bold">{@group_total_members}</p>
                  <p class="text-xs text-base-content/40">
                    {gettext("%{count} models", count: MapSet.size(@group_alias_ids))}
                  </p>
                </div>
                <div>
                  <p class="text-[10px] uppercase tracking-wide text-base-content/40">
                    {gettext("Spend/month")}
                  </p>
                  <p class="text-lg font-bold text-success">
                    ${format_decimal(@group_monthly_spend)}
                  </p>
                  <p class="text-xs text-base-content/40">{gettext("UTC month")}</p>
                </div>
              </div>
              <.link
                navigate={~p"/stats/profiles/#{@group.id}"}
                class="btn btn-sm btn-ghost gap-1.5"
                id="group-config-stats-link"
              >
                <.icon name="hero-chart-bar" class="w-4 h-4" />
                {gettext("View stats")}
              </.link>
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
              sort_field={@sort_field}
              sort_direction={@sort_direction}
              sort_event="sort_members"
              empty?={@members_empty?}
            >
              <:col :let={member} label={gettext("Member")} field={:email}>
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
                      {gettext("own")}
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
                      {gettext("own")}
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
                    {gettext("%{count} from limit profile",
                      count: length(MapSet.to_list(@group_alias_ids))
                    )}
                  </button>
                  <span
                    :if={extra_model_ids(@extra_models, member.id) != []}
                    class="badge badge-sm badge-accent"
                  >
                    +{length(extra_model_ids(@extra_models, member.id))} extra
                  </span>
                </div>
              </:col>
              <:col :let={member} label={gettext("Router")}>
                <div id={"router-state-#{member.id}"} class="flex flex-col gap-0.5 items-start">
                  <span class={[
                    "badge badge-sm",
                    router_state_badge_class(router_state(member))
                  ]}>
                    {router_state_label(router_state(member))}
                  </span>
                  <span class="text-[10px] text-base-content/50">
                    {gettext("effective: %{state}",
                      state: router_effective_label(router_effective?(member, @group))
                    )}
                  </span>
                </div>
              </:col>
              <:col :let={member} label={gettext("Monthly cap (UTC month)")}>
                <div id={"credit-#{member.id}"} class="min-w-[150px]">
                  <Stats.budget_cell credit={Map.get(@member_credits, member.id)} />
                </div>
              </:col>
              <:col :let={member} label={gettext("Spend/month")} field={:spend} align="right">
                <% mb = Map.get(@member_budgets, member.id, %{monthly_spend: Decimal.new(0)}) %>
                <span class="font-mono text-sm">${format_decimal(mb.monthly_spend)}</span>
              </:col>
              <:col :let={member} label={gettext("Usage")}>
                <% tier = Map.get(@usage_tiers_by_member, member.id) %>
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
                  <span class="badge badge-sm badge-ghost" title={gettext("No activity in 30 days")}>
                    —
                  </span>
                <% end %>
              </:col>
              <:action :let={member}>
                <.link
                  navigate={~p"/budget/topups?owner_kind=user&owner_id=#{member.user_id}"}
                  class="btn btn-xs btn-ghost"
                  id={"topup-#{member.id}"}
                  title={gettext("Grant top-up")}
                  aria-label={gettext("Grant top-up")}
                >
                  <.icon name="hero-arrow-up-circle" class="w-3.5 h-3.5" />
                </.link>
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
                  data-confirm={
                    gettext(
                      "Remove this member from the limit profile? This action cannot be undone."
                    )
                  }
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
            <.admin_pagination
              id="members-pagination"
              page={@page}
              per_page={@per_page}
              total={@total_count}
              total_pages={@total_pages}
            />
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

          <%!-- Acceso SmartRouter: tri-estado (heredar / permitir / negar) con el
               estado EFECTIVO siempre a la vista. --%>
          <div class="mb-4 pb-4 border-b border-base-300">
            <p class="text-xs text-base-content/50 uppercase tracking-wide mb-2">
              {gettext("SmartRouter access")}
            </p>
            <p class="text-xs text-base-content/40 mb-2">
              {gettext(
                "Inherit follows the limit profile; allow or deny overrides it for this member only."
              )}
            </p>
            <div class="flex flex-wrap items-center gap-2" id={"router-access-#{member.id}"}>
              <button
                type="button"
                phx-click="set_router_access"
                phx-value-id={member.id}
                phx-value-state="inherit"
                class={[
                  "btn btn-xs",
                  if(router_state(member) == :inherit, do: "btn-primary", else: "btn-ghost")
                ]}
                id={"router-access-inherit-#{member.id}"}
                aria-pressed={router_state(member) == :inherit}
              >
                {gettext("Inherit")}
              </button>
              <button
                type="button"
                phx-click="set_router_access"
                phx-value-id={member.id}
                phx-value-state="allow"
                class={[
                  "btn btn-xs",
                  if(router_state(member) == :allow, do: "btn-primary", else: "btn-ghost")
                ]}
                id={"router-access-allow-#{member.id}"}
                aria-pressed={router_state(member) == :allow}
              >
                {gettext("Allow")}
              </button>
              <button
                type="button"
                phx-click="set_router_access"
                phx-value-id={member.id}
                phx-value-state="deny"
                class={[
                  "btn btn-xs",
                  if(router_state(member) == :deny, do: "btn-primary", else: "btn-ghost")
                ]}
                id={"router-access-deny-#{member.id}"}
                aria-pressed={router_state(member) == :deny}
              >
                {gettext("Deny")}
              </button>
            </div>
            <p
              class="text-xs text-base-content/60 mt-2 flex items-center gap-2"
              id={"router-effective-#{member.id}"}
            >
              {gettext("Effective access:")}
              <span class={[
                "badge badge-sm",
                if(router_effective?(member, @group), do: "badge-success", else: "badge-error")
              ]}>
                {router_effective_label(router_effective?(member, @group))}
              </span>
              <span class="text-base-content/40">({router_source_label(member)})</span>
            </p>
          </div>

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
