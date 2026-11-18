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
  alias Tokengate.Accounts
  alias Tokengate.Accounts.Group
  alias Tokengate.Budgets
  alias Tokengate.Providers
  alias Tokengate.Providers.{Model, GroupModel}
  alias Tokengate.Repo

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
        |> assign(:group_search, "")
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

  # Loads the full dataset ONCE per mount (and after data mutations that
  # change groups themselves). Search and modal toggles must NOT come through
  # here — they filter in-memory / touch no data (see the assign-only handlers).
  defp load_groups(socket) do
    groups =
      from(t in Group,
        preload: [:group_members],
        order_by: [asc: t.name]
      )
      |> Repo.all()

    granted_models =
      from(tma in GroupModel, select: {tma.group_id, tma.model_id})
      |> Repo.all()
      |> Enum.group_by(fn {group_id, _} -> group_id end, fn {_, model_id} -> model_id end)

    models_by_org =
      from(ma in Model, order_by: [asc: ma.name])
      |> Repo.all()
      |> Enum.group_by(fn _ma -> "all" end)

    # Budget + spend rollup per group and per member. Se reusa el rollup de
    # `Budgets` (misma definición de límite/consumo que /stats) en vez de
    # recomputarlo aquí: la copia local convertía "todos sin límite" en $0.00
    # en lugar de "sin límite", y el límite venía de un `nil` hardcodeado.
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    member_budgets = Budgets.list_member_budgets(timezone)

    group_budgets =
      member_budgets
      |> Budgets.rollup_group_budgets()
      |> Map.new(fn budget -> {budget.group.id, budget} end)

    socket
    |> assign(:all_groups, groups)
    |> stream_groups()
    |> assign(:groups_empty?, groups == [])
    |> assign(:granted_models, granted_models)
    |> assign(:models_by_org, models_by_org)
    |> assign(:group_budgets, group_budgets)
  end

  # Re-streams the (already loaded) groups filtered by the current search.
  # Pure assign work: zero queries.
  defp stream_groups(socket) do
    search = socket.assigns[:group_search] || ""
    search_down = String.downcase(search)

    filtered =
      Enum.filter(socket.assigns.all_groups, fn t ->
        search == "" or String.contains?(String.downcase(t.name), search_down)
      end)

    socket
    |> stream(:groups, filtered, reset: true)
    |> assign(:groups_empty?, filtered == [])
  end

  ## Events — group CRUD ---------------------------------------------------

  @impl true
  def handle_event("search_groups", %{"group_search" => search}, socket) do
    # Groups are already in memory — filter + re-stream, no queries.
    {:noreply, socket |> assign(:group_search, search) |> stream_groups()}
  end

  @impl true
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

  def handle_event("delete_group", %{"id" => group_id}, socket) do
    case fetch_group(group_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Limit profile not found."))}

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
  # full load_groups() (groups + members + models + destinations + 2 spend
  # aggregates).
  defp refresh_granted_models(socket) do
    granted_models =
      from(tma in GroupModel, select: {tma.group_id, tma.model_id})
      |> Repo.all()
      |> Enum.group_by(fn {group_id, _} -> group_id end, fn {_, model_id} -> model_id end)

    assign(socket, :granted_models, granted_models)
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
         |> load_groups()}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field} #{message}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, gettext("Could not delete: %{reason}", reason: msg))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the limit profile."))}
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
         |> refresh_granted_models()}

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
            <div class="flex items-center gap-2">
              <%!-- Un `phx-change` exige que el input viva dentro de un <form>:
                   sin él, LiveView lanza "form events require the input to be
                   inside a form" y el buscador nunca llega al servidor. --%>
              <form
                id="groups-search-form"
                phx-change="search_groups"
                phx-submit="search_groups"
                phx-debounce="200"
              >
                <input
                  type="text"
                  name="group_search"
                  value={@group_search}
                  placeholder={gettext("Search limit profile…")}
                  class="input input-sm w-48"
                />
              </form>
              <.button phx-click="new_group" id="new-group-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New limit profile")}
              </.button>
            </div>
          </:actions>
        </.header>

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
              Listo
            </button>
          </:footer>
        </.modal>

        <%!-- Listado: una fila por perfil de límites (antes eran cards). --%>
        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="groups"
            rows={@streams.groups}
            row_item={fn {_id, group} -> group end}
            row_class="align-top"
            empty?={@groups_empty?}
          >
            <:col :let={group} label={gettext("Limit profile")}>
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
            <:col :let={group} label={gettext("Members")} align="right">
              <span class="font-mono text-sm">{length(group.group_members)}</span>
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
            <:col :let={group} label={gettext("Spend/month")} align="right">
              <% credit = group_credit(group, @group_budgets) %>
              <p class="font-mono text-sm">${format_decimal(get_spend(group, @group_budgets))}</p>
              <div
                id={"group-credit-#{group.id}"}
                class="text-[11px] whitespace-nowrap"
                title={credit.label}
              >
                <span class={["font-medium", credit.class]}>{credit.value}</span>
              </div>
            </:col>
            <:action :let={group}>
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
                phx-click="delete_group"
                phx-value-id={group.id}
                class="btn btn-xs btn-ghost text-error gap-1"
                id={"delete-#{group.id}"}
                title={gettext("Delete")}
                data-confirm={gettext("Delete limit profile? This action cannot be undone.")}
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" /> {gettext("Delete")}
              </button>
            </:action>
            <:empty>
              <.icon name="hero-user-group" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{gettext("No limit profiles yet.")}</p>
            </:empty>
          </.table>
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

  # Límite de la sub para la tarjeta. El número que se edita es el límite de la
  # propia sub, pero ese valor lo HEREDA cada miembro (no es un pozo común), así
  # que el consumo agregado contra ese número mediría cosas distintas. La barra
  # usa el rollup de `Budgets` —suma de los límites efectivos de los miembros
  # contra la suma de su gasto debitado—, que es la misma definición que /stats
  # y hace que numerador, denominador y % sean coherentes.
  defp group_credit(group, group_budgets) do
    budget = Map.get(group_budgets, group.id)

    cond do
      group.unlimited_spend ->
        %{label: gettext("Monthly budget"), value: "ilimitado", class: "text-success"}

      is_nil(budget) or is_nil(budget.monthly_limit_usd) ->
        %{label: gettext("Monthly budget"), value: gettext("No budget"), class: "text-warning"}

      true ->
        %{
          label: gettext("Monthly budget"),
          value:
            "#{format_decimal(budget.monthly_spend_usd)} / #{format_decimal(budget.monthly_limit_usd)}",
          class: credit_class(budget.monthly_pct)
        }
    end
  end

  defp credit_class(nil), do: "text-base-content/60"
  defp credit_class(pct) when pct >= 100, do: "text-error"
  defp credit_class(pct) when pct >= 80, do: "text-warning"
  defp credit_class(_pct), do: "text-success"
end
