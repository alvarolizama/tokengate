defmodule TokengateWeb.GroupsLive do
  @moduledoc """
  Admin-only CRUD for limit profiles («Perfil de límites»; antes «sub» y «grupo»)
  + per-profile model grants.

  Only admins (global_role == "admin") can access this page. Non-admins
  are redirected to /dashboard with an error flash.

  Un perfil de límites (internamente «group», antes «sub» en la UI) es el sujeto
  que aporta el techo de gasto mensual y los límites de concurrencia/RPM a sus
  miembros. El límite mensual se edita aquí, en su propio formulario.

  Los webhooks de observabilidad ya no cuelgan del perfil de límites: son globales y se
  gestionan en `TokengateWeb.ObservabilityLive` (/operations/observability).
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  import TokengateWeb.AdminComponents
  import TokengateWeb.KpiHelpers, only: [kpi_card: 1]
  alias Tokengate.Accounts
  alias Tokengate.Accounts.{Group, GroupMember, User}
  alias Tokengate.Budgets
  alias Tokengate.Providers
  alias Tokengate.Providers.{Model, GroupModel}
  alias Tokengate.Repo
  alias TokengateWeb.StatsHelpers, as: Stats

  @per_page 30
  @sort_columns ~w(name members monthly_cap spend)a

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user.global_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to access this section."))
       |> redirect(to: "/dashboard")}
    else
      socket =
        socket
        |> assign(:page_title, gettext("Limit profiles") <> " · Tokengate")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:form, nil)
        |> assign(:editing_group_id, nil)
        |> assign(:editing_models_group_id, nil)
        |> assign(:delete_target_id, nil)
        |> assign(:delete_target_name, nil)
        |> assign(:search_query, "")
        |> assign(:sort_field, :name)
        |> assign(:sort_direction, :asc)
        |> assign(:page, 1)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, 0)
        |> assign(:total_pages, 1)
        |> load_groups()

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
        {:halt, put_flash(socket, :error, gettext("Not authorized."))}
      end
    end)
  end

  ## Data loading ---------------------------------------------------------

  defp load_groups(socket) do
    page =
      Accounts.list_groups_page(
        search: socket.assigns[:search_query] || "",
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        sort_field: socket.assigns.sort_field,
        sort_direction: socket.assigns.sort_direction
      )

    groups = page.entries
    group_ids = Enum.map(groups, & &1.id)

    member_counts =
      if group_ids == [] do
        %{}
      else
        from(gm in GroupMember,
          where: gm.group_id in ^group_ids,
          group_by: gm.group_id,
          select: {gm.group_id, count(gm.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    granted_models =
      if group_ids == [] do
        %{}
      else
        from(tma in GroupModel,
          where: tma.group_id in ^group_ids,
          select: {tma.group_id, tma.model_id}
        )
        |> Repo.all()
        |> Enum.group_by(fn {group_id, _} -> group_id end, fn {_, model_id} -> model_id end)
      end

    models_by_org =
      from(ma in Model, order_by: [asc: ma.name])
      |> Repo.all()
      |> Enum.group_by(fn _ma -> "all" end)

    # Budget + spend rollup per group via cached Budgets.list_group_budgets/1.
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    group_budgets =
      timezone
      |> Budgets.list_group_budgets()
      |> Map.new(fn budget -> {budget.group.id, budget} end)

    kpis = compute_kpis(group_budgets)

    sorted_groups =
      if socket.assigns.sort_field in Accounts.group_page_sql_sorts() do
        groups
      else
        sort_groups(
          groups,
          socket.assigns.sort_field,
          socket.assigns.sort_direction,
          member_counts,
          group_budgets
        )
      end

    socket
    |> assign(:all_groups, groups)
    |> assign(:member_counts, member_counts)
    |> assign(:granted_models, granted_models)
    |> assign(:models_by_org, models_by_org)
    |> assign(:group_budgets, group_budgets)
    |> assign(:kpis, kpis)
    |> assign(:page, page.page)
    |> assign(:total_count, page.total)
    |> assign(:total_pages, page.total_pages)
    |> assign(:groups_empty?, page.total == 0)
    |> stream(:groups, sorted_groups, reset: true)
  end

  defp compute_kpis(group_budgets) do
    total_profiles = Repo.aggregate(Group, :count, :id)

    unlimited_profiles =
      Repo.aggregate(from(g in Group, where: g.unlimited_spend == true), :count, :id)

    capped_profiles =
      Repo.aggregate(
        from(g in Group, where: not g.unlimited_spend and not is_nil(g.monthly_spend_limit_usd)),
        :count,
        :id
      )

    total_members = Repo.aggregate(GroupMember, :count, :id)
    total_users = Repo.aggregate(User, :count, :id)

    budget_values = Map.values(group_budgets)

    total_spend =
      Enum.reduce(budget_values, Decimal.new(0), fn b, acc ->
        Decimal.add(acc, b.real_monthly_spend_usd)
      end)

    alert_profiles =
      Enum.count(budget_values, fn b ->
        not b.group.unlimited_spend and is_number(b.monthly_pct) and b.monthly_pct >= 80
      end)

    %{
      total_profiles: total_profiles,
      unlimited_profiles: unlimited_profiles,
      capped_profiles: capped_profiles,
      no_budget_profiles: max(total_profiles - unlimited_profiles - capped_profiles, 0),
      total_members: total_members,
      unassigned_users: max(total_users - total_members, 0),
      total_spend: total_spend,
      alert_profiles: alert_profiles
    }
  end

  defp sort_groups(groups, field, direction, member_counts, group_budgets) do
    Enum.sort_by(
      groups,
      fn g ->
        {sort_value(g, field, member_counts, group_budgets), String.downcase(g.name || "")}
      end,
      fn {val_a, name_a}, {val_b, name_b} ->
        case compare_sort_values(val_a, val_b, direction) do
          :eq -> name_a <= name_b
          order -> order == :lt
        end
      end
    )
  end

  defp sort_value(g, :members, member_counts, _group_budgets),
    do: Map.get(member_counts, g.id, 0)

  defp sort_value(g, :monthly_cap, _member_counts, _group_budgets) do
    cond do
      g.unlimited_spend -> {2, Decimal.new(0)}
      not is_nil(g.monthly_spend_limit_usd) -> {1, g.monthly_spend_limit_usd}
      true -> {0, Decimal.new(0)}
    end
  end

  defp sort_value(g, :spend, _member_counts, group_budgets),
    do: get_spend(g, group_budgets)

  defp sort_value(g, _field, _member_counts, _group_budgets),
    do: String.downcase(g.name || "")

  defp compare_vals({tier_a, %Decimal{} = dec_a}, {tier_b, %Decimal{} = dec_b}) do
    if tier_a == tier_b,
      do: Decimal.compare(dec_a, dec_b),
      else: if(tier_a < tier_b, do: :lt, else: :gt)
  end

  defp compare_vals(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b)

  defp compare_vals(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp compare_sort_values(a, b, direction) do
    case {compare_vals(a, b), direction} do
      {:eq, _} -> :eq
      {:lt, :asc} -> :lt
      {:lt, :desc} -> :gt
      {:gt, :asc} -> :gt
      {:gt, :desc} -> :lt
    end
  end

  ## Events — search / sort / pagination -----------------------------------

  @impl true
  def handle_event("search_groups", %{"q" => search}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, search)
     |> assign(:page, 1)
     |> load_groups()}
  end

  def handle_event("search_groups", %{"group_search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, search)
     |> assign(:page, 1)
     |> load_groups()}
  end

  def handle_event("go_to_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:page, parse_page(page))
     |> load_groups()}
  end

  def handle_event("sort_groups", %{"field" => field}, socket) do
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
       |> load_groups()}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Events — group CRUD ---------------------------------------------------

  def handle_event("new_group", _params, socket) do
    changeset = Accounts.change_group(%Group{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :group))
     |> assign(:editing_group_id, :new)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_group_id, nil)}
  end

  def handle_event("edit_models", %{"id" => group_id}, socket) do
    case fetch_group(group_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Limit profile not found."))}

      group ->
        {:noreply, assign(socket, :editing_models_group_id, group.id)}
    end
  end

  def handle_event("close_models", _params, socket) do
    {:noreply, assign(socket, :editing_models_group_id, nil)}
  end

  def handle_event("edit_group", %{"id" => group_id}, socket) do
    case fetch_group(group_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Limit profile not found."))}

      group ->
        changeset = Accounts.change_group(group)

        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: :group))
         |> assign(:editing_group_id, group.id)}
    end
  end

  def handle_event("save_group", %{"group" => group_params}, socket) do
    save_group(socket, socket.assigns.editing_group_id, group_params)
  end

  def handle_event("open_delete_modal", %{"id" => group_id, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(:delete_target_id, group_id)
     |> assign(:delete_target_name, name)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply,
     socket
     |> assign(:delete_target_id, nil)
     |> assign(:delete_target_name, nil)}
  end

  def handle_event("delete_group", %{"id" => group_id}, socket) do
    case fetch_group(group_id) do
      nil ->
        {:noreply,
         socket
         |> assign(:delete_target_id, nil)
         |> assign(:delete_target_name, nil)
         |> put_flash(:error, gettext("Limit profile not found."))}

      group ->
        delete_group(socket, group)
    end
  end

  ## Events — model grants ------------------------------------------------

  def handle_event("toggle_model", %{"target-id" => group_id, "model-id" => model_id}, socket) do
    case fetch_group(group_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Limit profile not found."))}

      group ->
        toggle_group_model(socket, group.id, model_id)
    end
  end

  # Catch-all: an event with an unexpected payload (or from a stale client)
  # leaves the socket untouched instead of raising FunctionClauseError and
  # killing the LiveView.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Private helpers — save ----------------------------------------------

  # Surgical refresh: only the table that actually changed, instead of the
  # full load_groups().
  defp refresh_granted_models(socket, group_id) do
    group_ids = Enum.map(socket.assigns.all_groups, & &1.id)

    granted_models =
      if group_ids == [] do
        %{}
      else
        from(tma in GroupModel,
          where: tma.group_id in ^group_ids,
          select: {tma.group_id, tma.model_id}
        )
        |> Repo.all()
        |> Enum.group_by(fn {gid, _} -> gid end, fn {_, model_id} -> model_id end)
      end

    socket = assign(socket, :granted_models, granted_models)

    case Enum.find(socket.assigns.all_groups, &(&1.id == group_id)) do
      nil -> socket
      group -> stream_insert(socket, :groups, group)
    end
  end

  # Body of `delete_group`: only a row that actually exists reaches the
  # context, so a stale/forged id becomes a flash instead of a crash.
  defp delete_group(socket, %Group{} = group) do
    case Accounts.delete_group(group) do
      {:ok, _} ->
        audit(socket, "group.delete", "group", group.id, %{"name" => group.name})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Limit profile deleted."))
         |> assign(:delete_target_id, nil)
         |> assign(:delete_target_name, nil)
         |> load_groups()}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field} #{message}" end)
          |> Enum.join(", ")

        {:noreply,
         socket
         |> assign(:delete_target_id, nil)
         |> assign(:delete_target_name, nil)
         |> put_flash(:error, gettext("Could not delete: %{reason}", reason: msg))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:delete_target_id, nil)
         |> assign(:delete_target_name, nil)
         |> put_flash(:error, gettext("Could not delete the limit profile."))}
    end
  end

  # Body of `toggle_model` (grant <-> revoke) for a profile that exists.
  defp toggle_group_model(socket, group_id, model_id) do
    group_alias_ids = Map.get(socket.assigns.granted_models, group_id, [])

    granted? = model_id not in group_alias_ids

    result =
      if granted? do
        Providers.grant_model_to_group(group_id, model_id)
      else
        Providers.revoke_model_from_group(group_id, model_id)
      end

    case result do
      {:ok, _} ->
        audit(socket, "group.model_access_toggle", "group", group_id, %{
          "model_id" => model_id,
          "granted" => granted?
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Models updated."))
         |> refresh_granted_models(group_id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
    end
  end

  # A client-supplied id reaches `Repo.get` as a string: a non-UUID would raise
  # `Ecto.Query.CastError` and kill the LiveView, so it is cast first and a
  # missing row is just `nil` (the caller shows a flash).
  defp fetch_group(group_id) do
    with {:ok, group_id} <- Ecto.UUID.cast(group_id) do
      Accounts.get_group(group_id)
    else
      _ -> nil
    end
  end

  # A submit already in flight lands right after Cancel cleared the editing
  # id: no-op instead of a FunctionClauseError that would lose the form.
  defp save_group(socket, nil, _group_params), do: {:noreply, socket}

  defp save_group(socket, :new, group_params) do
    case Accounts.create_group(group_params) do
      {:ok, group} ->
        audit(socket, "group.create", "group", group.id, %{"name" => group.name})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Limit profile created."))
         |> assign(:form, nil)
         |> assign(:editing_group_id, nil)
         |> load_groups()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :group))}
    end
  end

  defp save_group(socket, group_id, group_params) when is_binary(group_id) do
    case fetch_group(group_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Limit profile not found."))}

      group ->
        update_group(socket, group, group_params)
    end
  end

  defp update_group(socket, %Group{} = group, group_params) do
    case Accounts.update_group(group, group_params) do
      {:ok, updated} ->
        audit(socket, "group.update", "group", updated.id, %{
          "name" => updated.name,
          "changes" =>
            Map.take(group_params, [
              "name",
              "default_concurrency_limit",
              "default_rpm_limit",
              "monthly_spend_limit_usd",
              "unlimited_spend"
            ])
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Limit profile updated."))
         |> assign(:form, nil)
         |> assign(:editing_group_id, nil)
         |> load_groups()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :group))}
    end
  end

  ## Template helpers -----------------------------------------------------

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

  defp default_direction_for(field) when field in [:members, :monthly_cap, :spend], do: :desc
  defp default_direction_for(_), do: :asc

  def format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  def format_decimal(nil), do: "—"
  def format_decimal(value), do: to_string(value)

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
          {gettext("Limit profiles")}
          <:subtitle>{gettext("Manage the limit profiles: cap, top-ups and models")}</:subtitle>
          <:actions>
            <div class="flex flex-wrap items-center gap-3">
              <.admin_search
                event="search_groups"
                value={@search_query}
                placeholder={gettext("Search profile…")}
                input_id="group-search"
              />
              <.button phx-click="new_group" id="new-group-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New limit profile")}
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- Resumen de perfiles de límites --%>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4" id="profiles-kpis">
          <.kpi_card
            id="profiles-kpi-total"
            label={gettext("Limit profiles")}
            icon="hero-user-group"
            accent="primary"
          >
            {@kpis.total_profiles}
            <:sub>
              {gettext("%{capped} capped · %{unlimited} unlimited",
                capped: @kpis.capped_profiles,
                unlimited: @kpis.unlimited_profiles
              )}
            </:sub>
          </.kpi_card>

          <.kpi_card
            id="profiles-kpi-members"
            label={gettext("Covered members")}
            icon="hero-users"
            accent="accent"
          >
            {@kpis.total_members}
            <:sub>
              <%= if @kpis.unassigned_users > 0 do %>
                <.link navigate={~p"/access/users"} class="link link-hover text-warning">
                  {gettext("%{count} users without profile", count: @kpis.unassigned_users)}
                </.link>
              <% else %>
                {gettext("All users assigned")}
              <% end %>
            </:sub>
          </.kpi_card>

          <.kpi_card
            id="profiles-kpi-spend"
            label={gettext("Monthly spend (UTC)")}
            icon="hero-currency-dollar"
            accent="primary"
          >
            ${format_decimal(@kpis.total_spend)}
            <:sub>{gettext("Across active limit profiles")}</:sub>
          </.kpi_card>

          <.kpi_card
            id="profiles-kpi-alerts"
            label={gettext("Profiles ≥80%")}
            icon="hero-exclamation-triangle"
            accent={if(@kpis.alert_profiles > 0, do: "warning", else: "neutral")}
          >
            {@kpis.alert_profiles}
            <:sub>
              <%= if @kpis.no_budget_profiles > 0 do %>
                {gettext("%{count} without monthly budget", count: @kpis.no_budget_profiles)}
              <% else %>
                {gettext("Near or at monthly cap")}
              <% end %>
            </:sub>
          </.kpi_card>
        </div>

        <%!-- Group form (create / edit) — modal --%>
        <.modal
          :if={@form}
          id="group-form-modal"
          title={
            if @editing_group_id == :new,
              do: gettext("New limit profile"),
              else: gettext("Edit limit profile")
          }
          on_close="cancel_form"
        >
          <.form for={@form} id="group-form" phx-submit="save_group">
            <.input
              field={@form[:name]}
              type="text"
              label={gettext("Name")}
              hint={gettext("Identifying name of the limit profile.")}
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <.input
                field={@form[:default_concurrency_limit]}
                type="number"
                label={gettext("Concurrency")}
                hint={
                  gettext(
                    "Concurrency per member. Each member can have an extra on top of this value."
                  )
                }
              />
              <.input
                field={@form[:default_rpm_limit]}
                type="number"
                label="RPM"
                hint={gettext("Requests per minute per member.")}
              />
            </div>
            <%!-- El techo mensual del presupuesto es el que heredan sus
                 miembros cuando no definen el suyo. --%>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mt-3">
              <.input
                field={@form[:monthly_spend_limit_usd]}
                type="number"
                step="0.01"
                min="0"
                label={gettext("Monthly limit (USD)")}
                hint={
                  gettext(
                    "Monthly cap of the limit profile. 0 = zero (cannot spend). Empty = no budget (top-ups only)."
                  )
                }
              />
              <.input
                field={@form[:unlimited_spend]}
                type="checkbox"
                label={gettext("Unlimited")}
                hint={gettext("Only path to unlimited; wins over the limit.")}
              />
            </div>
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary btn-sm" id="save-group-btn">
                {gettext("Save")}
              </button>
            </div>
          </.form>
        </.modal>

        <%!-- Models modal — manage model grants per group --%>
        <.modal
          :if={@editing_models_group_id}
          id={"models-modal-#{@editing_models_group_id}"}
          title={gettext("Limit profile models")}
          on_close="close_models"
        >
          <.model_picker
            id={"model-picker-#{@editing_models_group_id}"}
            models={Map.get(@models_by_org, "all", [])}
            granted_ids={Map.get(@granted_models, @editing_models_group_id, [])}
            toggle_event="toggle_model"
            target_value={@editing_models_group_id}
          />
          <:footer>
            <button
              type="button"
              phx-click="close_models"
              class="btn btn-primary btn-sm"
              id="close-models-btn"
            >
              {gettext("Done")}
            </button>
          </:footer>
        </.modal>

        <%!-- Delete confirmation modal --%>
        <.admin_delete_modal
          :if={@delete_target_id}
          id="delete-group-modal"
          on_close="cancel_delete"
          title={gettext("Delete limit profile")}
          target_label={@delete_target_name}
          target_span_id="delete-group-name"
          confirm_event="delete_group"
          confirm_value={@delete_target_id}
          confirm_button_id="confirm-delete-group"
          cancel_button_id="cancel-delete-group"
          warning_intro={gettext("Will be permanently erased:")}
          warning_items={[
            gettext("Limit profile memberships and member model overrides"),
            gettext("The models granted to the limit profile"),
            gettext("API keys associated with those memberships")
          ]}
        />

        <%!-- Listado: una fila por perfil de límites (antes eran cards). --%>
        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="groups"
            rows={@streams.groups}
            row_item={fn {_id, group} -> group end}
            row_class="align-top"
            sort_field={@sort_field}
            sort_direction={@sort_direction}
            sort_event="sort_groups"
            empty?={@groups_empty?}
          >
            <:col :let={group} label={gettext("Limit profile")} field={:name}>
              <p class="font-medium text-sm text-base-content truncate max-w-72">{group.name}</p>
              <div class="flex items-center gap-1.5 mt-1 flex-wrap">
                <button
                  phx-click="edit_models"
                  phx-value-id={group.id}
                  class="badge badge-sm badge-outline gap-1 hover:badge-primary transition-colors cursor-pointer"
                  id={"edit-models-#{group.id}"}
                  title={gettext("Manage the limit profile models")}
                >
                  <.icon name="hero-rectangle-stack" class="w-3 h-3" />
                  {gettext("%{count} models", count: length(Map.get(@granted_models, group.id, [])))}
                </button>
              </div>
            </:col>
            <:col :let={group} label={gettext("Members")} field={:members} align="right">
              <.link
                navigate={~p"/budget/profiles/#{group}/members"}
                class="link link-hover font-mono text-sm tabular-nums"
                id={"members-count-link-#{group.id}"}
                title={gettext("Manage members")}
              >
                {Map.get(@member_counts, group.id, 0)}
              </.link>
            </:col>
            <:col :let={group} label={gettext("Limits")} align="right">
              <div class="text-xs whitespace-nowrap">
                <p class="flex items-center justify-end gap-1">
                  <span class="text-base-content/50">Conc.</span>
                  <span class="font-mono">{group.default_concurrency_limit}</span>
                </p>
                <p class="flex items-center justify-end gap-1">
                  <span class="text-base-content/50">RPM</span>
                  <span class="font-mono">{group.default_rpm_limit}</span>
                </p>
              </div>
            </:col>
            <:col :let={group} label={gettext("Monthly cap")} field={:monthly_cap} align="right">
              <div id={"group-cap-#{group.id}"}>
                <%= cond do %>
                  <% group.unlimited_spend -> %>
                    <span
                      class="badge badge-sm badge-success badge-outline"
                      title={gettext("Marked unlimited: no monthly ceiling")}
                    >
                      {gettext("Unlimited")}
                    </span>
                  <% not is_nil(group.monthly_spend_limit_usd) -> %>
                    <p class="font-mono text-sm">
                      ${format_decimal(group.monthly_spend_limit_usd)}
                    </p>
                    <p class="text-[10px] text-base-content/50">{gettext("per member")}</p>
                  <% true -> %>
                    <span
                      class="badge badge-sm badge-warning badge-outline"
                      title={gettext("No monthly budget (top-ups only)")}
                    >
                      {gettext("No budget")}
                    </span>
                <% end %>
              </div>
            </:col>
            <:col :let={group} label={gettext("Spend/month")} field={:spend} align="right">
              <% budget = Map.get(@group_budgets, group.id) %>
              <p class="font-mono text-sm">${format_decimal(get_spend(group, @group_budgets))}</p>
              <div id={"group-credit-#{group.id}"} class="mt-1">
                <%= cond do %>
                  <% group.unlimited_spend -> %>
                    <span
                      class="badge badge-sm badge-success badge-outline"
                      title={gettext("Marked unlimited: no monthly ceiling")}
                    >
                      {gettext("Unlimited")}
                    </span>
                  <% budget && not is_nil(budget.monthly_limit_usd) -> %>
                    <div class="flex items-center justify-end gap-2 min-w-[150px]">
                      <Stats.budget_bar
                        compact
                        spend={budget.monthly_spend_usd}
                        limit={budget.monthly_limit_usd}
                        pct={budget.monthly_pct}
                      />
                      <Stats.budget_badge pct={budget.monthly_pct} />
                    </div>
                  <% not is_nil(group.monthly_spend_limit_usd) -> %>
                    <div class="flex items-center justify-end gap-2 min-w-[150px]">
                      <Stats.budget_bar
                        compact
                        spend={Decimal.new(0)}
                        limit={group.monthly_spend_limit_usd}
                        pct={0.0}
                      />
                      <Stats.budget_badge pct={0.0} />
                    </div>
                  <% true -> %>
                    <span
                      class="badge badge-sm badge-warning badge-outline"
                      title={gettext("No monthly budget")}
                    >
                      {gettext("No budget")}
                    </span>
                <% end %>
              </div>
            </:col>
            <:action :let={group}>
              <.link
                navigate={~p"/stats/profiles/#{group.id}"}
                class="btn btn-xs btn-ghost"
                id={"stats-#{group.id}"}
                title={gettext("View stats")}
                aria-label={gettext("View stats")}
              >
                <.icon name="hero-chart-bar" class="w-3.5 h-3.5" />
              </.link>
              <.link
                navigate={~p"/budget/profiles/#{group}/members"}
                class="btn btn-xs btn-ghost gap-1"
                id={"members-link-#{group.id}"}
                title={gettext("Members")}
              >
                <.icon name="hero-users" class="w-3.5 h-3.5" /> {gettext("Members")}
              </.link>
              <button
                phx-click="edit_group"
                phx-value-id={group.id}
                class="btn btn-xs btn-ghost gap-1"
                id={"edit-#{group.id}"}
                title={gettext("Edit")}
              >
                <.icon name="hero-pencil-square" class="w-3.5 h-3.5" /> {gettext("Edit")}
              </button>
              <button
                phx-click="open_delete_modal"
                phx-value-id={group.id}
                phx-value-name={group.name}
                class="btn btn-xs btn-ghost text-error gap-1"
                id={"delete-#{group.id}"}
                title={gettext("Delete")}
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" /> {gettext("Delete")}
              </button>
            </:action>
            <:empty>
              <.icon name="hero-user-group" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{gettext("No limit profiles yet.")}</p>
            </:empty>
          </.table>
          <.admin_pagination
            id="groups-pagination"
            page={@page}
            per_page={@per_page}
            total={@total_count}
            total_pages={@total_pages}
          />
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Render helpers ---------------------------------------------------------

  defp get_spend(group, group_budgets) do
    group_budgets
    |> Map.get(group.id, %{})
    |> Map.get(:real_monthly_spend_usd, Decimal.new(0))
  end
end
