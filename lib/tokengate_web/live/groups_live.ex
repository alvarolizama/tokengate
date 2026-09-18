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
        {:halt, put_flash(socket, :error, "No autorizado.")}
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
    {:noreply, assign(socket, :editing_models_group_id, group_id)}
  end

  def handle_event("close_models", _params, socket) do
    {:noreply, assign(socket, :editing_models_group_id, nil)}
  end

  def handle_event("edit_group", %{"id" => group_id}, socket) do
    group = Accounts.get_group!(group_id)
    changeset = Accounts.change_group(group)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :group))
     |> assign(:editing_group_id, group.id)}
  end

  def handle_event("save_group", %{"group" => group_params}, socket) do
    save_group(socket, socket.assigns.editing_group_id, group_params)
  end

  def handle_event("delete_group", %{"id" => group_id}, socket) do
    group = Accounts.get_group!(group_id)

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

  ## Events — model grants ------------------------------------------------

  def handle_event("toggle_model", %{"target-id" => group_id, "model-id" => model_id}, socket) do
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
         |> put_flash(:info, "Modelos actualizados.")
         |> refresh_granted_models()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
    end
  end

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

  ## Private helpers — save ----------------------------------------------

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
    group = Accounts.get_group!(group_id)

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
                <.icon name="hero-plus" class="w-4 h-4" /> Nuevo perfil de límites
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- Group form (create / edit) — modal --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_group_id == :new,
                  do: gettext("New limit profile"),
                  else: gettext("Edit limit profile")}
              </h2>
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
                    label="Concurrencia"
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
                    label="Límite mensual (USD)"
                    hint="Techo mensual del perfil de límites. 0 = cero (no deja gastar). Vacío = sin presupuesto (solo top-ups)."
                  />
                  <.input
                    field={@form[:unlimited_spend]}
                    type="checkbox"
                    label="Ilimitado"
                    hint="Único camino a ilimitado; gana sobre el límite."
                  />
                </div>
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-group-btn">Guardar</button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Models modal — manage model grants per group --%>
        <div
          :if={@editing_models_group_id}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id={"models-modal-#{@editing_models_group_id}"}
        >
          <div class="absolute inset-0 bg-black/50" phx-click="close_models" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">{gettext("Limit profile models")}</h2>
              <.model_picker
                id={"model-picker-#{@editing_models_group_id}"}
                models={Map.get(@models_by_org, "all", [])}
                granted_ids={Map.get(@granted_models, @editing_models_group_id, [])}
                toggle_event="toggle_model"
                target_value={@editing_models_group_id}
                empty_text="No hay modelos disponibles."
              />
              <div class="flex justify-end mt-4">
                <button
                  type="button"
                  phx-click="close_models"
                  class="btn btn-primary btn-sm"
                  id="close-models-btn"
                >
                  Listo
                </button>
              </div>
            </div>
          </div>
        </div>

        <div id="groups" phx-update="stream">
          <div :if={@groups_empty?} class="text-center py-12 text-base-content/40" id="groups-empty">
            <.icon name="hero-user-group" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>{gettext("No limit profiles yet.")}</p>
          </div>
          <div
            :for={{id, group} <- @streams.groups}
            id={id}
            class="card bg-base-100 border border-base-300 shadow-sm mb-3 transition-shadow hover:shadow-md"
          >
            <div class="card-body p-4">
              <%!-- Header row: identity + compact stats + actions --%>
              <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
                <div class="min-w-0 flex-1">
                  <h3 class="font-semibold text-base-content truncate">{group.name}</h3>
                  <p class="text-xs text-base-content/50">
                    {length(group.group_members)} miembros · conc. {group.default_concurrency_limit} · {group.default_rpm_limit} RPM
                  </p>
                </div>

                <%!-- Compact stats --%>
                <% credit = group_credit(group, @group_budgets) %>
                <div class="flex items-center gap-4 text-sm">
                  <div class="text-center">
                    <p class="text-[10px] uppercase tracking-wide text-base-content/40">
                      {gettext("Spend/month")}
                    </p>
                    <p class="font-bold">${format_decimal(get_spend(group, @group_budgets))}</p>
                  </div>
                  <div class="text-center" id={"group-credit-#{group.id}"}>
                    <p class="text-[10px] uppercase tracking-wide text-base-content/40">
                      {credit.label}
                    </p>
                    <p class={["font-bold", credit.class]}>{credit.value}</p>
                  </div>
                  <%!-- Models badge --%>
                  <button
                    phx-click="edit_models"
                    phx-value-id={group.id}
                    class="badge badge-sm badge-outline gap-1 hover:badge-primary transition-colors cursor-pointer"
                    id={"edit-models-#{group.id}"}
                    title={gettext("Manage the limit profile models")}
                  >
                    <.icon name="hero-rectangle-stack" class="w-3 h-3" />
                    {length(Map.get(@granted_models, group.id, []))} modelos
                  </button>
                </div>

                <%!-- Actions --%>
                <div class="flex gap-1 shrink-0">
                  <.link
                    navigate={~p"/budget/profiles/#{group}/members"}
                    class="btn btn-sm btn-ghost"
                    id={"members-link-#{group.id}"}
                  >
                    Miembros
                  </.link>
                  <button
                    phx-click="edit_group"
                    phx-value-id={group.id}
                    class="btn btn-sm btn-ghost"
                    id={"edit-#{group.id}"}
                  >
                    Editar
                  </button>
                  <button
                    phx-click="delete_group"
                    phx-value-id={group.id}
                    class="btn btn-sm btn-ghost text-error"
                    id={"delete-#{group.id}"}
                    data-confirm={gettext("Delete limit profile? This action cannot be undone.")}
                  >
                    Eliminar
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
