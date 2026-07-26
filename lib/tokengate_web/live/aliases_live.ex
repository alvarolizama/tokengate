defmodule TokengateWeb.AliasesLive do
  @moduledoc """
  CRUD for model_aliases + per-alias alias_provider management.

  Admins can create, edit, and delete aliases, and assign providers to each
  alias (provider_model, priority/weight, subscription_id, enabled toggle).
  Managers and regular users see a read-only list.

  Model aliases are organization-scoped. When creating, the admin picks
  an organization from a select. All existing aliases are listed regardless
  of organization.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Providers
  alias Tokengate.Providers.{ModelAlias, AliasProvider, Provider, Subscription}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    is_admin = user && user.global_role == "admin"

    socket =
      socket
      |> assign(:page_title, "Aliases · Tokengate")
      |> assign(:is_admin, is_admin)
      |> assign(:form, nil)
      |> assign(:editing_alias_id, nil)
      |> assign(:provider_form, nil)
      |> assign(:provider_form_alias_id, nil)
      |> assign(:editing_ap_id, nil)
      |> load_aliases()
      |> assign_form_data()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_aliases(socket) do
    aliases =
      from(ma in ModelAlias,
        left_join: aps in assoc(ma, :alias_providers),
        preload: [alias_providers: {aps, [:provider, :subscription]}],
        order_by: [asc: ma.name]
      )
      |> Repo.all()

    socket
    |> stream(:aliases, aliases, reset: true)
    |> assign(:aliases_empty?, aliases == [])
  end

  defp assign_form_data(socket) do
    socket
    |> assign(:organizations, Accounts.list_organizations())
    |> assign(:providers, Providers.list_providers())
    |> assign(:subscriptions, Providers.list_subscriptions())
    |> assign(:routing_strategies, ModelAlias.routing_strategies())
  end

  ## Events — alias CRUD ---------------------------------------------------

  @impl true
  def handle_event("new_alias", _params, socket) do
    if socket.assigns.is_admin do
      changeset = Providers.change_model_alias(%ModelAlias{routing_strategy: "priority"})

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :model_alias))
       |> assign(:editing_alias_id, :new)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_alias_id, nil)}
  end

  def handle_event("edit_alias", %{"id" => alias_id}, socket) do
    if socket.assigns.is_admin do
      model_alias = Providers.get_model_alias!(alias_id)
      changeset = Providers.change_model_alias(model_alias)

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :model_alias))
       |> assign(:editing_alias_id, model_alias.id)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("save_alias", %{"model_alias" => alias_params}, socket) do
    if socket.assigns.is_admin do
      save_alias(socket, socket.assigns.editing_alias_id, alias_params)
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("delete_alias", %{"id" => alias_id}, socket) do
    if socket.assigns.is_admin do
      alias_record = Providers.get_model_alias!(alias_id)

      has_providers? =
        Repo.exists?(from(ap in AliasProvider, where: ap.model_alias_id == ^alias_id))

      if has_providers? do
        {:noreply,
         put_flash(
           socket,
           :error,
           "No se puede eliminar: el alias tiene proveedores asignados. Elimínalos primero."
         )}
      else
        case Providers.delete_model_alias(alias_record) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Alias eliminado.")
             |> load_aliases()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo eliminar el alias.")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  ## Events — alias_provider management -------------------------------------

  def handle_event("new_alias_provider", %{"alias_id" => alias_id}, socket) do
    if socket.assigns.is_admin do
      changeset =
        Providers.change_alias_provider(%AliasProvider{
          model_alias_id: alias_id,
          enabled: true
        })

      {:noreply,
       socket
       |> assign(:provider_form_alias_id, alias_id)
       |> assign(:provider_form, to_form(changeset, as: :alias_provider))
       |> assign(:editing_ap_id, :new)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("cancel_alias_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:provider_form, nil)
     |> assign(:editing_ap_id, nil)}
  end

  def handle_event("edit_alias_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_alias_provider!(ap_id)
      changeset = Providers.change_alias_provider(ap)

      {:noreply,
       socket
       |> assign(:provider_form, to_form(changeset, as: :alias_provider))
       |> assign(:editing_ap_id, ap.id)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("save_alias_provider", %{"alias_provider" => ap_params}, socket) do
    if socket.assigns.is_admin do
      save_alias_provider(socket, socket.assigns.editing_ap_id, ap_params)
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("toggle_alias_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_alias_provider!(ap_id)
      new_enabled = !ap.enabled

      case Providers.update_alias_provider(ap, %{enabled: new_enabled}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Proveedor #{if new_enabled, do: "activado", else: "desactivado"}."
           )
           |> load_aliases()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo actualizar el proveedor.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("delete_alias_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_alias_provider!(ap_id)

      case Providers.delete_alias_provider(ap) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Proveedor eliminado del alias.")
           |> load_aliases()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo eliminar el proveedor.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  ## Private helpers — alias save ------------------------------------------

  defp save_alias(socket, :new, alias_params) do
    case Providers.create_model_alias(alias_params) do
      {:ok, _alias} ->
        {:noreply,
         socket
         |> put_flash(:info, "Alias creado.")
         |> assign(:form, nil)
         |> assign(:editing_alias_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model_alias))}
    end
  end

  defp save_alias(socket, alias_id, alias_params) when is_binary(alias_id) do
    alias_record = Providers.get_model_alias!(alias_id)

    case Providers.update_model_alias(alias_record, alias_params) do
      {:ok, _alias} ->
        {:noreply,
         socket
         |> put_flash(:info, "Alias actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_alias_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model_alias))}
    end
  end

  ## Private helpers — alias_provider save ---------------------------------

  defp save_alias_provider(socket, :new, ap_params) do
    ap_params = Map.put(ap_params, "model_alias_id", socket.assigns.provider_form_alias_id)

    case Providers.create_alias_provider(ap_params) do
      {:ok, _ap} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor asignado al alias.")
         |> assign(:provider_form, nil)
         |> assign(:editing_ap_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :alias_provider))}
    end
  end

  defp save_alias_provider(socket, ap_id, ap_params) when is_binary(ap_id) do
    ap = Providers.get_alias_provider!(ap_id)

    case Providers.update_alias_provider(ap, ap_params) do
      {:ok, _ap} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor actualizado.")
         |> assign(:provider_form, nil)
         |> assign(:editing_ap_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :alias_provider))}
    end
  end

  ## Helpers ---------------------------------------------------------------

  @doc "Routing strategy options for selects"
  def routing_strategy_options do
    [{"Prioridad", "priority"}, {"Round Robin", "round_robin"}]
  end

  @doc "Organization options for the select (id -> display)"
  def organization_options(organizations) do
    Enum.map(organizations, fn org -> {org.name, org.id} end)
  end

  @doc "Provider options for the select (id -> display)"
  def provider_options(providers) do
    Enum.map(providers, fn p -> {"#{p.name} (#{p.billing_type})", p.id} end)
  end

  @doc "Active subscriptions for a provider (for the subscription_id select)"
  def subscription_options_for_provider(subscriptions, provider_id) do
    subscriptions
    |> Enum.filter(fn s -> s.provider_id == provider_id end)
    |> Enum.map(fn s -> {"#{s.name} (#{s.status})", s.id} end)
  end

  @doc "Format a decimal for display"
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)

  @doc "Find alias_providers for a model_alias from the preloaded association"
  def alias_providers_for(%{alias_providers: aps}), do: aps
  def alias_providers_for(_), do: []

  @doc "Strategy label in Spanish"
  def strategy_label("priority"), do: "Prioridad"
  def strategy_label("round_robin"), do: "Round Robin"
  def strategy_label(_), do: "—"

  @doc "Provider name from preloaded provider"
  def provider_name(%{provider: %Provider{name: name}}), do: name
  def provider_name(_), do: "—"

  @doc "Subscription name from preloaded subscription"
  def subscription_name(%{subscription: %Subscription{name: name}}), do: name
  def subscription_name(_), do: "—"

  @doc "Enabled badge class"
  def enabled_badge(true), do: "badge-success"
  def enabled_badge(false), do: "badge-ghost"

  @doc "Enabled label"
  def enabled_label(true), do: "Activo"
  def enabled_label(false), do: "Inactivo"

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          Aliases de Modelos
          <:subtitle>Configura aliases de modelos y sus proveedores de routing</:subtitle>
          <:actions :if={@is_admin}>
            <button
              phx-click="new_alias"
              class="btn btn-primary btn-sm"
              id="new-alias-btn"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo Alias
            </button>
          </:actions>
        </.header>

        <%!-- Alias list --%>
        <div id="aliases" phx-update="stream">
          <div
            :if={@aliases_empty?}
            id="aliases-empty"
            class="text-center py-12 text-base-content/40"
          >
            <.icon name="hero-cpu-chip" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>No hay aliases de modelos configurados.</p>
          </div>

          <div :for={{id, model_alias} <- @streams.aliases} id={id} class="space-y-3">
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-5">
                <div class="flex items-start justify-between gap-4">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 flex-wrap">
                      <h3 class="font-semibold text-base-content truncate">
                        {model_alias.name}
                      </h3>
                      <span class="badge badge-sm badge-outline">
                        {strategy_label(model_alias.routing_strategy)}
                      </span>
                      <span class="badge badge-sm badge-ghost">
                        {length(alias_providers_for(model_alias))} proveedores
                      </span>
                    </div>
                    <p class="text-sm text-base-content/60 mt-1">{model_alias.display_name}</p>
                    <div class="flex gap-4 mt-2 text-xs text-base-content/50">
                      <span>
                        Precio entrada:
                        <strong>{fmt_dec(model_alias.market_input_price_per_1m)}</strong>
                      </span>
                      <span>
                        Precio salida:
                        <strong>{fmt_dec(model_alias.market_output_price_per_1m)}</strong>
                      </span>
                      <span>
                        Contexto: <strong>{model_alias.context_window}</strong> tokens
                      </span>
                    </div>
                  </div>

                  <div class="flex gap-2 shrink-0">
                    <%= if @is_admin do %>
                      <button
                        phx-click="edit_alias"
                        phx-value-id={model_alias.id}
                        class="btn btn-sm btn-ghost"
                        id={"edit-alias-#{model_alias.id}"}
                      >
                        <.icon name="hero-pencil-square" class="w-4 h-4" /> Editar
                      </button>
                      <button
                        phx-click="delete_alias"
                        phx-value-id={model_alias.id}
                        data-confirm="¿Eliminar este alias? Esta acción no se puede deshacer."
                        class="btn btn-sm btn-ghost text-error"
                        id={"delete-alias-#{model_alias.id}"}
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
                </div>

                <%!-- Alias providers list (inline) --%>
                <div class="mt-4 pt-4 border-t border-base-200">
                  <div class="flex items-center justify-between mb-2">
                    <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                      Proveedores asignados
                    </h4>
                    <%= if @is_admin do %>
                      <button
                        phx-click="new_alias_provider"
                        phx-value-alias_id={model_alias.id}
                        class="btn btn-xs btn-primary"
                        id={"new-ap-#{model_alias.id}"}
                      >
                        <.icon name="hero-plus" class="w-3 h-3" /> Asignar Proveedor
                      </button>
                    <% end %>
                  </div>

                  <div
                    :if={alias_providers_for(model_alias) == []}
                    class="text-sm text-base-content/40 py-2"
                  >
                    No hay proveedores asignados.
                  </div>

                  <div :if={alias_providers_for(model_alias) != []} class="overflow-x-auto">
                    <table class="table table-sm">
                      <thead>
                        <tr>
                          <th>Proveedor</th>
                          <th>Modelo</th>
                          <th>Prioridad</th>
                          <th>Peso</th>
                          <th>Subscripción</th>
                          <th>Estado</th>
                          <%= if @is_admin do %>
                            <th>Acciones</th>
                          <% end %>
                        </tr>
                      </thead>
                      <tbody>
                        <tr
                          :for={ap <- alias_providers_for(model_alias)}
                          id={"alias-provider-#{ap.id}"}
                        >
                          <td class="font-medium">{provider_name(ap)}</td>
                          <td><code class="text-sm">{ap.provider_model}</code></td>
                          <td>{ap.priority || "—"}</td>
                          <td>{ap.weight || "—"}</td>
                          <td>{subscription_name(ap)}</td>
                          <td>
                            <span class={["badge", "badge-sm", enabled_badge(ap.enabled)]}>
                              {enabled_label(ap.enabled)}
                            </span>
                          </td>
                          <%= if @is_admin do %>
                            <td>
                              <div class="flex gap-1">
                                <button
                                  phx-click="toggle_alias_provider"
                                  phx-value-id={ap.id}
                                  class="btn btn-xs btn-ghost"
                                  id={"toggle-ap-#{ap.id}"}
                                >
                                  <.icon name="hero-arrow-path" class="w-3 h-3" />
                                </button>
                                <button
                                  phx-click="edit_alias_provider"
                                  phx-value-id={ap.id}
                                  class="btn btn-xs btn-ghost"
                                  id={"edit-ap-#{ap.id}"}
                                >
                                  <.icon name="hero-pencil-square" class="w-3 h-3" />
                                </button>
                                <button
                                  phx-click="delete_alias_provider"
                                  phx-value-id={ap.id}
                                  data-confirm="¿Eliminar este proveedor del alias?"
                                  class="btn btn-xs btn-ghost text-error"
                                  id={"delete-ap-#{ap.id}"}
                                >
                                  <.icon name="hero-trash" class="w-3 h-3" />
                                </button>
                              </div>
                            </td>
                          <% end %>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Alias form (new/edit) --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_alias_id == :new, do: "Nuevo Alias", else: "Editar Alias"}
              </h2>

              <.form for={@form} id="alias-form" phx-submit="save_alias">
                <.input
                  field={@form[:organization_id]}
                  type="select"
                  label="Organización"
                  options={organization_options(@organizations)}
                  prompt="Selecciona una organización"
                  required
                />
                <.input field={@form[:name]} type="text" label="Nombre (identificador)" required />
                <.input field={@form[:display_name]} type="text" label="Nombre para mostrar" required />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@form[:market_input_price_per_1m]}
                    type="number"
                    label="Precio entrada /1M"
                    step="any"
                    required
                  />
                  <.input
                    field={@form[:market_output_price_per_1m]}
                    type="number"
                    label="Precio salida /1M"
                    step="any"
                    required
                  />
                </div>
                <.input
                  field={@form[:context_window]}
                  type="number"
                  label="Ventana de contexto (tokens)"
                  required
                />
                <.input
                  field={@form[:routing_strategy]}
                  type="select"
                  label="Estrategia de routing"
                  options={routing_strategy_options()}
                  required
                />

                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-alias-btn">
                    Guardar
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Alias provider form (new/edit) --%>
        <div :if={@provider_form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_alias_provider" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_ap_id == :new, do: "Asignar Proveedor", else: "Editar Proveedor"}
              </h2>

              <.form for={@provider_form} id="alias-provider-form" phx-submit="save_alias_provider">
                <.input
                  field={@provider_form[:provider_id]}
                  type="select"
                  label="Proveedor"
                  options={provider_options(@providers)}
                  prompt="Selecciona un proveedor"
                  required
                />
                <.input
                  field={@provider_form[:provider_model]}
                  type="text"
                  label="Modelo del proveedor"
                  required
                />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@provider_form[:priority]}
                    type="number"
                    label="Prioridad (menor = primero)"
                  />
                  <.input
                    field={@provider_form[:weight]}
                    type="number"
                    label="Peso (round robin)"
                  />
                </div>
                <.input
                  field={@provider_form[:subscription_id]}
                  type="select"
                  label="Subscripción (opcional, solo proveedores con suscripción)"
                  options={subscription_options_for_provider(@subscriptions, nil)}
                  prompt="Sin subscripción"
                />
                <.input
                  field={@provider_form[:enabled]}
                  type="checkbox"
                  label="Habilitado"
                />

                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_alias_provider" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-ap-btn">
                    Guardar
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
