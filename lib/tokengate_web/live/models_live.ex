defmodule TokengateWeb.ModelsLive do
  @moduledoc """
  CRUD for model_aliases + per-model model_provider management.

  Admins can create, edit, and delete models, and assign providers to each
  model (provider_model, priority, enabled toggle).
  Managers and regular users see a read-only list.

  Models are global. Admins can create, edit, and delete models,
  and assign providers to each model (provider_model, priority, enabled toggle).
  Managers and regular users see a read-only list.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers
  alias Tokengate.Providers.{ModelAlias, ModelProvider, Provider}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    is_admin = user && user.global_role == "admin"

    socket =
      socket
      |> assign(:page_title, "Modelos · Tokengate")
      |> assign(:is_admin, is_admin)
      |> assign(:form, nil)
      |> assign(:editing_alias_id, nil)
      |> assign(:provider_form, nil)
      |> assign(:provider_form_alias_id, nil)
      |> assign(:editing_ap_id, nil)
      |> assign(:provider_models, [])
      |> assign(:provider_models_loading, false)
      |> assign(:provider_form_credential_id, nil)
      |> assign(:current_billing_mode, "pay_per_token")
      |> load_aliases()
      |> assign_form_data()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_aliases(socket) do
    aliases =
      from(ma in ModelAlias,
        left_join: aps in assoc(ma, :model_providers),
        preload: [model_providers: {aps, [credential: :provider]}],
        order_by: [asc: ma.name]
      )
      |> Repo.all()

    socket
    |> stream(:aliases, aliases, reset: true)
    |> assign(:aliases_empty?, aliases == [])
  end

  defp assign_form_data(socket) do
    credentials =
      from(c in Tokengate.Providers.Credential,
        where: c.status == "active",
        preload: [:provider],
        order_by: [asc: c.inserted_at]
      )
      |> Repo.all()

    socket
    |> assign(:credentials_for_select, credentials)
  end

  ## Events — alias CRUD ---------------------------------------------------

  @impl true
  def handle_event("new_alias", _params, socket) do
    if socket.assigns.is_admin do
      changeset = Providers.change_model_alias(%ModelAlias{})

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
        Repo.exists?(from(ap in ModelProvider, where: ap.model_alias_id == ^alias_id))

      if has_providers? do
        {:noreply,
         put_flash(
           socket,
           :error,
           "No se puede eliminar: el modelo tiene proveedores asignados. Elimínalos primero."
         )}
      else
        case Providers.delete_model_alias(alias_record) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Modelo eliminado.")
             |> load_aliases()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo eliminar el modelo.")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  ## Events — model_provider management -------------------------------------

  def handle_event("new_model_provider", %{"alias_id" => alias_id}, socket) do
    if socket.assigns.is_admin do
      changeset =
        Providers.change_model_provider(%ModelProvider{
          model_alias_id: alias_id,
          enabled: true
        })

      {:noreply,
       socket
       |> assign(:provider_form_alias_id, alias_id)
       |> assign(:provider_form, to_form(changeset, as: :model_provider))
       |> assign(:editing_ap_id, :new)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("cancel_model_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:provider_form, nil)
     |> assign(:editing_ap_id, nil)
     |> assign(:provider_models, [])
     |> assign(:provider_models_loading, false)
     |> assign(:provider_form_credential_id, nil)
     |> assign(:current_billing_mode, "pay_per_token")}
  end

  def handle_event("edit_model_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_model_provider!(ap_id)
      changeset = Providers.change_model_provider(ap)

      {:noreply,
       socket
       |> assign(:provider_form, to_form(changeset, as: :model_provider))
       |> assign(:editing_ap_id, ap.id)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("save_model_provider", %{"model_provider" => ap_params}, socket) do
    if socket.assigns.is_admin do
      # Extract pricing fields (prefixed with "pricing_") into a nested map
      {pricing_fields, provider_fields} =
        Enum.reduce(ap_params, {%{}, %{}}, fn
          {"pricing_" <> name, value}, {p, ap} ->
            {Map.put(p, name, value), ap}

          {key, value}, {p, ap} ->
            {p, Map.put(ap, key, value)}
        end)

      # Only keep pricing if at least input or output price is present
      pricing =
        if pricing_fields["input_price_per_1m"] in ["", nil] and
             pricing_fields["output_price_per_1m"] in ["", nil] do
          %{}
        else
          pricing_fields
        end

      save_model_provider(
        socket,
        socket.assigns.editing_ap_id,
        Map.put(provider_fields, "pricing", pricing)
      )
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("provider_form_changed", %{"model_provider" => ap_params}, socket) do
    if socket.assigns.is_admin do
      credential_id = ap_params["credential_id"]

      billing_mode =
        ap_params["billing_mode"] || socket.assigns[:current_billing_mode] || "pay_per_token"

      socket = assign(socket, :current_billing_mode, billing_mode)

      cond do
        credential_id == "" or credential_id == nil ->
          {:noreply, assign(socket, :provider_models, [])}

        credential_id != socket.assigns[:provider_form_credential_id] ->
          {:noreply,
           socket
           |> assign(:provider_form_credential_id, credential_id)
           |> assign(:provider_models_loading, true)
           |> fetch_provider_models(credential_id)}

        true ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_model_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_model_provider!(ap_id)
      new_enabled = !ap.enabled

      case Providers.update_model_provider(ap, %{enabled: new_enabled}) do
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

  def handle_event("delete_model_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_model_provider!(ap_id)

      case Providers.delete_model_provider(ap) do
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

  def handle_event("reorder_providers", %{"alias_id" => alias_id, "ids" => ids}, socket) do
    if socket.assigns.is_admin do
      valid_ids =
        from(ap in ModelProvider, where: ap.model_alias_id == ^alias_id, select: ap.id)
        |> Repo.all()
        |> MapSet.new()

      if is_list(ids) and ids != [] and Enum.all?(ids, &MapSet.member?(valid_ids, &1)) do
        {:ok, _} =
          Repo.transaction(fn ->
            ids
            |> Enum.with_index(1)
            |> Enum.each(fn {ap_id, priority} ->
              from(ap in ModelProvider, where: ap.id == ^ap_id)
              |> Repo.update_all(
                set: [
                  priority: priority,
                  updated_at: DateTime.truncate(DateTime.utc_now(), :second)
                ]
              )
            end)
          end)

        {:noreply, load_aliases(socket)}
      else
        {:noreply, put_flash(socket, :error, "Orden inválido para este modelo.")}
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
         |> put_flash(:info, "Modelo creado.")
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
         |> put_flash(:info, "Modelo actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_alias_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model_alias))}
    end
  end

  ## Private helpers — model_provider save ---------------------------------

  defp fetch_provider_models(socket, credential_id) do
    credential =
      Enum.find(socket.assigns.credentials_for_select, &(&1.id == credential_id))

    if credential do
      provider = credential.provider
      lv_pid = self()

      Task.start(fn ->
        result = Tokengate.Proxy.OpenAIAdapter.list_models(provider, credential)
        send(lv_pid, {:provider_models_result, result})
      end)

      socket
    else
      socket
      |> assign(:provider_models, [])
      |> assign(:provider_models_loading, false)
    end
  end

  @impl true
  def handle_info({:provider_models_result, result}, socket) do
    case result do
      {:ok, models} ->
        {:noreply,
         socket
         |> assign(:provider_models, models)
         |> assign(:provider_models_loading, false)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:provider_models, [])
         |> assign(:provider_models_loading, false)
         |> put_flash(:error, "No se pudieron cargar los modelos del proveedor.")}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp save_model_provider(socket, :new, ap_params) do
    ap_params = Map.put(ap_params, "model_alias_id", socket.assigns.provider_form_alias_id)

    {pricing_params, ap_params} = Map.pop(ap_params, "pricing", %{})

    Repo.transaction(fn ->
      with {:ok, ap} <- Providers.create_model_provider(ap_params),
           {:ok, _pricing} <- maybe_create_pricing(ap, pricing_params) do
        ap
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, _ap} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor asignado al modelo.")
         |> assign(:provider_form, nil)
         |> assign(:editing_ap_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :model_provider))}
    end
  end

  defp save_model_provider(socket, ap_id, ap_params) when is_binary(ap_id) do
    ap = Providers.get_model_provider!(ap_id)

    case Providers.update_model_provider(ap, ap_params) do
      {:ok, _ap} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor actualizado.")
         |> assign(:provider_form, nil)
         |> assign(:editing_ap_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :model_provider))}
    end
  end

  defp maybe_create_pricing(_ap, pricing) when pricing in [nil, %{}, ""], do: {:ok, nil}

  defp maybe_create_pricing(ap, pricing) do
    pricing_params =
      pricing
      |> Map.put("model_provider_id", ap.id)
      |> Map.put_new("effective_from", DateTime.utc_now() |> DateTime.truncate(:second))

    Providers.create_model_pricing(pricing_params)
  end

  ## Helpers ---------------------------------------------------------------

  @doc "Credential options for the select (id -> display)"
  def credential_options(credentials) do
    Enum.map(credentials, fn c ->
      label =
        if c.name do
          "#{c.provider.name} · #{c.name}"
        else
          "#{c.provider.name} · #{mask_key(c.api_key_encrypted)}"
        end

      {label, c.id}
    end)
  end

  @doc "Mask an api key for display: show only the last 4 chars."
  def mask_key(nil), do: "—"
  def mask_key(""), do: "—"
  def mask_key(key) when byte_size(key) <= 4, do: "****"

  def mask_key(key) do
    len = String.length(key)

    String.slice(key, len - 4, 4)
    |> then(&"••••••#{&1}")
  end

  @doc "Format a decimal for display"
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)

  @doc "Find model_providers for a model_alias from the preloaded association (priority ASC, nils last)"
  def model_providers_for(%{model_providers: aps}) do
    Enum.sort_by(aps, fn ap -> {is_nil(ap.priority), ap.priority || 0} end)
  end

  def model_providers_for(_), do: []

  @doc "Whether the credential has a human-readable alias (name) set"
  def credential_named?(%{name: name}), do: is_binary(name) and name != ""
  def credential_named?(_), do: false

  @doc "Provider name from preloaded credential"
  def provider_name(%{credential: %{provider: %Provider{name: name}}}), do: name
  def provider_name(_), do: "—"

  @doc "Credential label: alias if set, otherwise masked key"
  def credential_label(%{name: name}) when is_binary(name) and name != "", do: name
  def credential_label(%{api_key_encrypted: key}), do: mask_key(key)
  def credential_label(_), do: "—"

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
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Modelos
          <:subtitle>Configura modelos y sus proveedores de routing</:subtitle>
          <:actions :if={@is_admin}>
            <button
              phx-click="new_alias"
              class="btn btn-primary btn-sm"
              id="new-model-btn"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo Modelo
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
            <p>No hay modelos configurados.</p>
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
                      <span class="badge badge-sm badge-ghost">
                        {length(model_providers_for(model_alias))} proveedores
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
                        data-confirm="¿Eliminar este modelo? Esta acción no se puede deshacer."
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
                        phx-click="new_model_provider"
                        phx-value-alias_id={model_alias.id}
                        class="btn btn-xs btn-primary"
                        id={"new-ap-#{model_alias.id}"}
                      >
                        <.icon name="hero-plus" class="w-3 h-3" /> Asignar Proveedor
                      </button>
                    <% end %>
                  </div>

                  <div
                    :if={model_providers_for(model_alias) == []}
                    class="text-sm text-base-content/40 py-2"
                  >
                    No hay proveedores asignados.
                  </div>

                  <div :if={model_providers_for(model_alias) != []} class="overflow-x-auto">
                    <table class="table table-sm">
                      <thead>
                        <tr>
                          <th :if={@is_admin} class="w-8" title="Arrastra para reordenar prioridad">
                          </th>
                          <th>Proveedor</th>
                          <th>Modelo</th>
                          <th>Prioridad</th>
                          <th>Estado</th>
                          <%= if @is_admin do %>
                            <th>Acciones</th>
                          <% end %>
                        </tr>
                      </thead>
                      <tbody
                        id={"ap-sortable-#{model_alias.id}"}
                        phx-hook="SortableProviders"
                        data-alias-id={model_alias.id}
                      >
                        <tr
                          :for={ap <- model_providers_for(model_alias)}
                          id={"alias-provider-#{ap.id}"}
                          data-id={ap.id}
                          draggable={to_string(@is_admin)}
                          class={[@is_admin && "cursor-grab active:cursor-grabbing"]}
                        >
                          <td :if={@is_admin} class="w-8 text-base-content/30">
                            <.icon name="hero-bars-3" class="w-4 h-4" />
                          </td>
                          <td class="font-medium">
                            {provider_name(ap)}
                            <span
                              :if={ap.credential && credential_named?(ap.credential)}
                              class="badge badge-xs badge-outline font-normal ml-1"
                              title="Alias de la API key"
                            >
                              <.icon name="hero-key" class="w-3 h-3" />
                              {ap.credential.name}
                            </span>
                            <span
                              :if={ap.credential && !credential_named?(ap.credential)}
                              class="text-xs text-base-content/40 ml-1"
                            >
                              {mask_key(ap.credential.api_key_encrypted)}
                            </span>
                          </td>
                          <td><code class="text-sm">{ap.provider_model}</code></td>
                          <td>
                            <span class="badge badge-xs badge-ghost">{ap.priority || "—"}</span>
                          </td>
                          <td>
                            <span class={["badge", "badge-sm", enabled_badge(ap.enabled)]}>
                              {enabled_label(ap.enabled)}
                            </span>
                          </td>
                          <%= if @is_admin do %>
                            <td>
                              <div class="flex gap-1">
                                <button
                                  phx-click="toggle_model_provider"
                                  phx-value-id={ap.id}
                                  class="btn btn-xs btn-ghost"
                                  id={"toggle-ap-#{ap.id}"}
                                >
                                  <.icon name="hero-arrow-path" class="w-3 h-3" />
                                </button>
                                <button
                                  phx-click="edit_model_provider"
                                  phx-value-id={ap.id}
                                  class="btn btn-xs btn-ghost"
                                  id={"edit-ap-#{ap.id}"}
                                >
                                  <.icon name="hero-pencil-square" class="w-3 h-3" />
                                </button>
                                <button
                                  phx-click="delete_model_provider"
                                  phx-value-id={ap.id}
                                  data-confirm="¿Eliminar este proveedor del modelo?"
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
                {if @editing_alias_id == :new, do: "Nuevo Modelo", else: "Editar Modelo"}
              </h2>

              <.form for={@form} id="alias-form" phx-submit="save_alias">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Nombre (identificador)"
                  required
                  hint="Nombre interno del modelo, ej. gpt-4o. Debe ser único."
                />
                <.input
                  field={@form[:display_name]}
                  type="text"
                  label="Nombre para mostrar"
                  required
                  hint="Nombre visible para los usuarios en /v1/models."
                />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@form[:market_input_price_per_1m]}
                    type="number"
                    label="Precio entrada /1M"
                    step="any"
                    required
                    hint="Precio de referencia de mercado por 1M tokens de entrada."
                  />
                  <.input
                    field={@form[:market_output_price_per_1m]}
                    type="number"
                    label="Precio salida /1M"
                    step="any"
                    required
                    hint="Precio de referencia de mercado por 1M tokens de salida."
                  />
                </div>
                <.input
                  field={@form[:context_window]}
                  type="number"
                  label="Ventana de contexto (tokens)"
                  required
                  hint="Tamaño máximo de contexto del modelo en tokens."
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
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_model_provider" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_ap_id == :new, do: "Asignar Proveedor", else: "Editar Proveedor"}
              </h2>

              <.form
                for={@provider_form}
                id="alias-provider-form"
                phx-submit="save_model_provider"
                phx-change="provider_form_changed"
              >
                <.input
                  field={@provider_form[:credential_id]}
                  type="select"
                  label="Credencial (API Key)"
                  options={credential_options(@credentials_for_select)}
                  prompt="Selecciona una credencial"
                  required
                  hint="La API key específica que servirá este modelo. Cada credencial tiene su propio circuit breaker y prioridad."
                />

                <%= if @provider_models_loading do %>
                  <div class="flex items-center gap-2 text-sm text-base-content/50 py-2">
                    <span class="loading loading-spinner loading-xs"></span>
                    Cargando modelos del proveedor…
                  </div>
                <% end %>

                <%= if @provider_models_loading == false and @provider_models != [] do %>
                  <.input
                    field={@provider_form[:provider_model]}
                    type="select"
                    label="Modelo del proveedor"
                    options={@provider_models}
                    prompt="Selecciona un modelo"
                    required
                    hint="Modelos disponibles para esta credencial, obtenidos en vivo del proveedor."
                  />
                <% else %>
                  <.input
                    field={@provider_form[:provider_model]}
                    type="text"
                    label="Modelo del proveedor"
                    required
                    placeholder="Primero selecciona una credencial"
                    hint="Selecciona una credencial para ver los modelos disponibles."
                  />
                <% end %>
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@provider_form[:priority]}
                    type="number"
                    label="Prioridad (menor = primero)"
                    hint="Orden de preferencia. Menor número = se intenta primero. Si cae, salta al siguiente."
                  />
                  <.input
                    field={@provider_form[:billing_mode]}
                    type="select"
                    label="Facturación"
                    options={[
                      {"Pay per token", "pay_per_token"},
                      {"Incluido (suscripción)", "included"}
                    ]}
                    hint="Pay per token: cobra por uso. Incluido: suscripción/RPM, gasto real = $0."
                  />
                </div>

                <.input
                  field={@provider_form[:enabled]}
                  type="checkbox"
                  label="Habilitado"
                  hint="Si está apagado, este provider no recibe tráfico del modelo."
                />

                <%= if @editing_ap_id == :new and (@current_billing_mode || "pay_per_token") == "pay_per_token" do %>
                  <div class="mt-4 pt-4 border-t border-base-200">
                    <p class="text-sm font-semibold text-base-content mb-3">Pricing (opcional)</p>
                    <p class="text-xs text-base-content/50 mb-3">
                      Define el costo por 1M tokens. Si lo dejas vacío, se usará el costo reportado por el proveedor o el precio de mercado.
                    </p>
                    <div class="grid grid-cols-2 gap-3">
                      <.input
                        field={@provider_form[:pricing_input_price_per_1m]}
                        type="number"
                        step="0.01"
                        label="Input $/1M"
                        placeholder="ej. 0.15"
                      />
                      <.input
                        field={@provider_form[:pricing_output_price_per_1m]}
                        type="number"
                        step="0.01"
                        label="Output $/1M"
                        placeholder="ej. 0.60"
                      />
                      <.input
                        field={@provider_form[:pricing_cache_read_price_per_1m]}
                        type="number"
                        step="0.01"
                        label="Cache read $/1M"
                        placeholder="ej. 0.015"
                      />
                      <.input
                        field={@provider_form[:pricing_cache_creation_price_per_1m]}
                        type="number"
                        step="0.01"
                        label="Cache creation $/1M"
                        placeholder="ej. 0.30"
                      />
                    </div>
                  </div>
                <% end %>

                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_model_provider" class="btn btn-ghost btn-sm">
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
