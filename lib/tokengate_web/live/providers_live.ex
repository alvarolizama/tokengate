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
    |> stream(:providers, providers)
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
      Repo.exists?(from(ap in Tokengate.Providers.AliasProvider, where: ap.provider_id == ^provider_id))

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
         |> put_flash(:info, "Credencial #{if(new_status == "active", do: "activada", else: "desactivada")}.")
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
end
