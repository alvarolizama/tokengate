defmodule TokengateWeb.ProvidersLive do
  @moduledoc """
  Admin CRUD for providers + per-provider credential management.

  Providers are global (not org-scoped). Each provider can carry multiple
  credentials (api_key_encrypted, max_rpm, max_concurrent, status).

  Deleting a provider that is referenced by alias_providers is blocked
  with a friendly Spanish flash message.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers
  alias Tokengate.Providers.{Provider, Credential}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Proveedores · Tokengate")
      |> assign(:form, nil)
      |> assign(:editing_provider_id, nil)
      |> assign(:credential_provider_id, nil)
      |> assign(:credential_form, nil)
      |> load_providers()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_providers(socket) do
    providers =
      from(p in Provider,
        left_join: c in assoc(p, :credentials),
        preload: [credentials: c],
        order_by: [asc: p.name]
      )
      |> Repo.all()

    socket
    |> assign(:providers, providers)
    |> assign(:providers_empty?, providers == [])
  end

  ## Events — provider CRUD ------------------------------------------------

  @impl true
  def handle_event("new_provider", _params, socket) do
    changeset = Providers.change_provider(%Provider{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :provider))
     |> assign(:editing_provider_id, :new)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_provider_id, nil)}
  end

  def handle_event("edit_provider", %{"id" => provider_id}, socket) do
    provider = Providers.get_provider!(provider_id)
    changeset = Providers.change_provider(provider)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :provider))
     |> assign(:editing_provider_id, provider.id)}
  end

  def handle_event("save_provider", %{"provider" => provider_params}, socket) do
    save_provider(socket, socket.assigns.editing_provider_id, provider_params)
  end

  def handle_event("delete_provider", %{"id" => provider_id}, socket) do
    provider = Providers.get_provider!(provider_id)

    referenced? =
      Repo.exists?(
        from(ap in Tokengate.Providers.AliasProvider, where: ap.provider_id == ^provider_id)
      )

    if referenced? do
      {:noreply,
       put_flash(
         socket,
         :error,
         "No se puede eliminar: el proveedor está en uso por uno o más alias de modelos."
       )}
    else
      case Providers.delete_provider(provider) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Proveedor eliminado.")
           |> load_providers()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo eliminar el proveedor.")}
      end
    end
  end

  ## Events — credential management ----------------------------------------

  def handle_event("manage_credentials", %{"id" => provider_id}, socket) do
    {:noreply,
     socket
     |> assign(:credential_provider_id, provider_id)
     |> assign(:credential_form, nil)}
  end

  def handle_event("new_credential", %{"provider_id" => provider_id}, socket) do
    changeset =
      Providers.change_credential(%Credential{provider_id: provider_id, status: "active"})

    {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}
  end

  def handle_event("cancel_credential", _params, socket) do
    {:noreply, assign(socket, :credential_form, nil)}
  end

  def handle_event("save_credential", %{"credential" => cred_params}, socket) do
    case Providers.create_credential(cred_params) do
      {:ok, _cred} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credencial creada.")
         |> assign(:credential_form, nil)
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}
    end
  end

  def handle_event("toggle_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)
    new_status = if cred.status == "active", do: "disabled", else: "active"

    case Providers.update_credential(cred, %{status: new_status}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Credencial #{if(new_status == "active", do: "activada", else: "desactivada")}."
         )
         |> load_providers()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar la credencial.")}
    end
  end

  def handle_event("delete_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    case Providers.delete_credential(cred) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credencial eliminada.")
         |> load_providers()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar la credencial.")}
    end
  end

  ## Private helpers — provider save --------------------------------------

  defp save_provider(socket, :new, provider_params) do
    case Providers.create_provider(provider_params) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor creado.")
         |> assign(:form, nil)
         |> assign(:editing_provider_id, nil)
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :provider))}
    end
  end

  defp save_provider(socket, provider_id, provider_params) when is_binary(provider_id) do
    provider = Providers.get_provider!(provider_id)

    case Providers.update_provider(provider, provider_params) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_provider_id, nil)
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :provider))}
    end
  end

  ## Helpers ---------------------------------------------------------------

  @doc "Billing type options for selects"
  def billing_type_options do
    [{"Pay per token", "pay_per_token"}, {"Suscripción", "subscription"}]
  end

  @doc "Credentials for a provider (preloaded)."
  def credentials_for(%{credentials: creds}), do: creds
  def credentials_for(_), do: []

  @doc "Mask an api key for display: show only the last 4 chars."
  def mask_key(nil), do: "—"
  def mask_key(""), do: "—"
  def mask_key(key) when byte_size(key) <= 4, do: "****"

  def mask_key(key) do
    len = String.length(key)

    String.slice(key, len - 4, 4)
    |> then(&"••••••#{&1}")
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          Proveedores
          <:subtitle>Providers de LLM y sus credenciales</:subtitle>
        </.header>

        <div class="flex justify-end">
          <button phx-click="new_provider" class="btn btn-primary btn-sm" id="new-provider-btn">
            <.icon name="hero-plus" class="w-4 h-4" /> Nuevo proveedor
          </button>
        </div>

        <%!-- Provider form (create / edit) --%>
        <div
          :if={@form}
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="provider-form-card"
        >
          <div class="card-body">
            <h2 class="text-base font-semibold mb-2">
              {if @editing_provider_id == :new, do: "Nuevo proveedor", else: "Editar proveedor"}
            </h2>
            <.form for={@form} id="provider-form" phx-submit="save_provider">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <.input field={@form[:name]} type="text" label="Nombre" placeholder="openai" />
                <.input
                  field={@form[:base_url]}
                  type="text"
                  label="Base URL"
                  placeholder="https://api.openai.com"
                />
                <.input
                  field={@form[:billing_type]}
                  type="select"
                  label="Tipo de facturación"
                  prompt="Selecciona tipo"
                  options={billing_type_options()}
                />
                <div class="flex items-end pb-2">
                  <.input
                    field={@form[:track_real_usage]}
                    type="checkbox"
                    label="Trackear uso real del provider"
                  />
                </div>
              </div>
              <div class="flex gap-2 mt-4">
                <button type="submit" class="btn btn-primary btn-sm" id="save-provider-btn">Guardar</button>
                <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">Cancelar</button>
              </div>
            </.form>
          </div>
        </div>

        <div
          :if={@providers_empty?}
          class="text-center py-12 text-base-content/40"
          id="providers-empty"
        >
          <.icon name="hero-server-stack" class="w-10 h-10 mx-auto mb-2 opacity-40" />
          <p>No hay proveedores todavía.</p>
        </div>

        <div id="providers" class="space-y-3">
          <div
            :for={provider <- @providers}
            id={"providers-#{provider.id}"}
            class="card bg-base-100 border border-base-300 shadow-sm"
          >
            <div class="card-body p-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <div class="flex items-center gap-2">
                    <h3 class="font-semibold text-base-content">{provider.name}</h3>
                    <span class={[
                      "badge badge-sm",
                      if(provider.billing_type == "subscription",
                        do: "badge-info",
                        else: "badge-accent"
                      )
                    ]}>
                      {if provider.billing_type == "subscription",
                        do: "Suscripción",
                        else: "Pay per token"}
                    </span>
                    <span :if={provider.track_real_usage} class="badge badge-sm badge-ghost">
                      Uso real
                    </span>
                  </div>
                  <p class="text-xs text-base-content/50 mt-1 font-mono">{provider.base_url}</p>
                  <p class="text-xs text-base-content/50 mt-0.5">
                    {length(credentials_for(provider))} credencial(es)
                  </p>
                </div>
                <div class="flex gap-2">
                  <button
                    phx-click="manage_credentials"
                    phx-value-id={provider.id}
                    class="btn btn-sm btn-ghost"
                    id={"credentials-#{provider.id}"}
                  >
                    <.icon name="hero-key" class="w-4 h-4" /> Credenciales
                  </button>
                  <button
                    phx-click="edit_provider"
                    phx-value-id={provider.id}
                    class="btn btn-sm btn-ghost"
                    id={"edit-#{provider.id}"}
                  >
                    <.icon name="hero-pencil-square" class="w-4 h-4" /> Editar
                  </button>
                  <button
                    phx-click="delete_provider"
                    phx-value-id={provider.id}
                    data-confirm="¿Eliminar este proveedor?"
                    class="btn btn-sm btn-ghost text-error"
                    id={"delete-#{provider.id}"}
                  >
                    <.icon name="hero-trash" class="w-4 h-4" /> Eliminar
                  </button>
                </div>
              </div>

              <%!-- Credentials panel --%>
              <div
                :if={@credential_provider_id == provider.id}
                class="mt-3 pt-3 border-t border-base-300"
                id={"credentials-panel-#{provider.id}"}
              >
                <div class="flex items-center justify-between mb-2">
                  <h4 class="text-sm font-semibold">Credenciales</h4>
                  <button
                    phx-click="new_credential"
                    phx-value-provider_id={provider.id}
                    class="btn btn-xs btn-ghost"
                    id={"new-credential-#{provider.id}"}
                  >
                    <.icon name="hero-plus" class="w-3 h-3" /> Nueva
                  </button>
                </div>

                <div :if={@credential_form} class="mb-3" id="credential-form-card">
                  <.form for={@credential_form} id="credential-form" phx-submit="save_credential">
                    <.input field={@credential_form[:provider_id]} type="hidden" />
                    <div class="grid grid-cols-1 sm:grid-cols-4 gap-3 items-end">
                      <.input
                        field={@credential_form[:api_key_encrypted]}
                        type="text"
                        label="API key"
                        placeholder="sk-..."
                      />
                      <.input field={@credential_form[:max_rpm]} type="number" label="Max RPM" />
                      <.input
                        field={@credential_form[:max_concurrent]}
                        type="number"
                        label="Max concurrencia"
                      />
                      <div class="flex gap-2">
                        <button type="submit" class="btn btn-primary btn-sm" id="save-credential-btn">
                          Guardar
                        </button>
                        <button
                          type="button"
                          phx-click="cancel_credential"
                          class="btn btn-ghost btn-sm"
                        >
                          Cancelar
                        </button>
                      </div>
                    </div>
                  </.form>
                </div>

                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Key</th>
                        <th>Max RPM</th>
                        <th>Max conc.</th>
                        <th>Estado</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={cred <- credentials_for(provider)} id={"credential-#{cred.id}"}>
                        <td>
                          <code class="text-sm font-mono">{mask_key(cred.api_key_encrypted)}</code>
                        </td>
                        <td>{cred.max_rpm || "—"}</td>
                        <td>{cred.max_concurrent || "—"}</td>
                        <td>
                          <span class={[
                            "badge badge-sm",
                            if(cred.status == "active", do: "badge-success", else: "badge-ghost")
                          ]}>
                            {if cred.status == "active", do: "Activa", else: "Desactivada"}
                          </span>
                        </td>
                        <td class="text-right">
                          <button
                            phx-click="toggle_credential"
                            phx-value-id={cred.id}
                            class="btn btn-xs btn-ghost"
                            id={"toggle-credential-#{cred.id}"}
                          >
                            {if cred.status == "active", do: "Desactivar", else: "Activar"}
                          </button>
                          <button
                            phx-click="delete_credential"
                            phx-value-id={cred.id}
                            data-confirm="¿Eliminar esta credencial?"
                            class="btn btn-xs btn-ghost text-error"
                            id={"delete-credential-#{cred.id}"}
                          >
                            Eliminar
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
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
