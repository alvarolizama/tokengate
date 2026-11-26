defmodule TokengateWeb.ProviderKeysLive do
  @moduledoc """
  API keys (upstream credentials) of ONE provider — `/catalog/providers/:id/keys`.

  The index (`ProvidersLive`) lists providers and owns everything provider-wide:
  identity, status, limits and per-service paths. This page owns the key
  lifecycle: create, rotate the secret, enable/disable, reactivate after an
  upstream 401/402/403, reset the circuit breaker, delete.

  A credential is deliberately thin — an alias plus a secret. The operational
  limits (RPM, concurrency, per-user concurrency, receive timeout) belong to the
  provider and every one of its keys inherits them, so they show here read-only.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Providers
  alias Tokengate.Providers.{Credential, ModelProvider}
  alias Tokengate.Repo

  @impl true
  def mount(%{"id" => provider_id}, _session, socket) do
    case fetch_provider(provider_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Provider not found."))
         |> redirect(to: ~p"/catalog/providers")}

      provider ->
        # Live in-flight counts per credential (open upstream connections),
        # recomputed on every `:inflight_started`/`:inflight_done` PubSub event
        # without a DB hit.
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tokengate.PubSub, Tokengate.Logs.Inflight.topic())
        end

        user = socket.assigns[:current_user]

        socket =
          socket
          |> assign(:page_title, gettext("API keys") <> " · " <> provider.name)
          |> assign(:provider, provider)
          |> assign(:credential_form, nil)
          |> assign(:limits_form, nil)
          |> assign(:editing_credential_id, nil)
          |> assign(:is_admin, user && user.global_role == "admin")
          |> assign(:credential_inflight, %{})
          |> require_admin_hook()

        {:ok, socket}
    end
  end

  # The page has ONE load point: the provider comes from mount, the rows and the
  # `?new=1` modal from here. A patch that only changes the query string
  # (`/keys` → `/keys?new=1`) then reuses this path instead of remounting or
  # duplicating the loading logic in every entry point.
  @impl true
  def handle_params(params, _uri, %{assigns: %{provider: _}} = socket) do
    {:noreply,
     socket
     |> load_keys()
     |> open_new_credential_form(params["new"] == "1")}
  end

  # A mount that redirected to the index has no provider to load.
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # `Repo.get/2` raises on an id that is not a UUID: a hand-typed URL would
  # crash the mount instead of landing on the index.
  defp fetch_provider(provider_id) do
    Providers.get_provider(provider_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  # Defense-in-depth: the router already gates this LiveView behind
  # live_session :admin, but a malicious client could fire events directly over
  # the WebSocket. Halt every event for non-admins.
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

  defp load_keys(socket) do
    provider = socket.assigns.provider

    credentials =
      from(c in Credential,
        where: c.provider_id == ^provider.id,
        order_by: [asc: c.inserted_at, asc: c.id]
      )
      |> Repo.all()

    credential_ids = Enum.map(credentials, & &1.id)

    # Model count per key in ONE query, not one per row.
    model_counts =
      if credential_ids == [] do
        %{}
      else
        from(mp in ModelProvider,
          where: mp.credential_id in ^credential_ids,
          group_by: mp.credential_id,
          select: {mp.credential_id, count(mp.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    # One Registry sweep for every breaker state instead of a call per
    # credential; unknown credentials default to :closed.
    breaker_statuses =
      Tokengate.Routing.CircuitBreakerManager.status_all()
      |> then(fn all -> Map.new(credentials, &{&1.id, Map.get(all, &1.id, :closed)}) end)

    socket
    |> assign(:credentials, credentials)
    |> assign(:credential_model_counts, model_counts)
    |> assign(:breaker_statuses, breaker_statuses)
    |> assign_inflight()
  end

  @inflight_refresh_ms 250

  defp assign_inflight(socket) do
    credential_counts =
      Tokengate.Logs.Inflight.count_by_credential()
      |> Map.new(fn %{credential_id: id, count: n} -> {id, n} end)

    assign(socket, :credential_inflight, credential_counts)
  end

  defp schedule_inflight_refresh(socket) do
    if socket.assigns[:inflight_scheduled] do
      socket
    else
      Process.send_after(self(), :refresh_inflight, @inflight_refresh_ms)
      assign(socket, :inflight_scheduled, true)
    end
  end

  ## Live in-flight refresh -------------------------------------------------

  @impl true
  def handle_info({:inflight_started, _entry}, socket) do
    {:noreply, schedule_inflight_refresh(socket)}
  end

  def handle_info({:inflight_done, _id}, socket) do
    {:noreply, schedule_inflight_refresh(socket)}
  end

  def handle_info(:refresh_inflight, socket) do
    {:noreply,
     socket
     |> assign(:inflight_scheduled, false)
     |> assign_inflight()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events — credential management ----------------------------------------

  @impl true
  def handle_event("new_credential", _params, socket) do
    {:noreply, open_new_credential_form(socket, true)}
  end

  # Every handler that names a credential goes through `fetch_credential/2`:
  # the id is cast (a hand-typed or non-UUID id is an ordinary miss, not a
  # CastError that kills the LiveView) and the row must belong to THIS page's
  # provider — an id from another provider is not a key the operator can see,
  # let alone toggle or delete. A miss answers with a flash and the socket
  # survives.
  def handle_event("edit_credential", %{"id" => cred_id}, socket) do
    with_credential(socket, cred_id, &open_edit_credential_form/2)
  end

  def handle_event("cancel_credential", _params, socket) do
    {:noreply, close_credential_form(socket)}
  end

  def handle_event("save_credential", %{"credential" => params}, socket) do
    # Only the two operator fields survive. `provider_id`, `status` and the
    # error bookkeeping are server-set, so a forged submit cannot re-parent the
    # key or flip its lifecycle state.
    attrs = Map.take(params, ["name", "api_key_encrypted"])

    case socket.assigns[:editing_credential_id] do
      nil ->
        {:noreply, create_credential(socket, attrs)}

      cred_id ->
        with_credential(socket, cred_id, fn socket, credential ->
          update_credential(socket, credential, attrs)
        end)
    end
  end

  def handle_event("save_credential", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("The credential form is missing."))}
  end

  def handle_event("toggle_credential", %{"id" => cred_id}, socket) do
    with_credential(socket, cred_id, &toggle_credential/2)
  end

  def handle_event("reactivate_credential", %{"id" => cred_id}, socket) do
    with_credential(socket, cred_id, &reactivate_credential/2)
  end

  def handle_event("reset_breaker", %{"id" => cred_id}, socket) do
    with_credential(socket, cred_id, &reset_breaker/2)
  end

  def handle_event("delete_credential", %{"id" => cred_id}, socket) do
    with_credential(socket, cred_id, &delete_credential/2)
  end

  def handle_event("edit_provider_limits", _params, socket) do
    changeset = Providers.change_provider(socket.assigns.provider)
    {:noreply, assign(socket, :limits_form, to_form(changeset, as: :provider))}
  end

  def handle_event("cancel_provider_limits", _params, socket) do
    {:noreply, assign(socket, :limits_form, nil)}
  end

  def handle_event("save_provider_limits", %{"provider" => params}, socket) do
    attrs =
      Map.take(params, [
        "max_rpm",
        "max_concurrent",
        "max_concurrent_per_user",
        "receive_timeout_ms"
      ])

    case Providers.update_provider(socket.assigns.provider, attrs) do
      {:ok, updated} ->
        audit(socket, "provider.update", "provider", updated.id, %{
          "name" => updated.name,
          "changes" => attrs
        })

        {:noreply,
         socket
         |> assign(:provider, updated)
         |> assign(:limits_form, nil)
         |> put_flash(:info, gettext("Provider updated."))}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :limits_form, to_form(%{changeset | action: :validate}, as: :provider))}
    end
  end

  def handle_event("save_provider_limits", _params, socket), do: {:noreply, socket}

  # Stale clients (a row removed in another tab, a replayed event) must not
  # crash the page.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Credential actions ----------------------------------------------------

  defp open_edit_credential_form(socket, credential) do
    socket
    |> assign(:credential_form, to_form(edit_changeset(credential), as: :credential))
    |> assign(:editing_credential_id, credential.id)
  end

  defp create_credential(socket, attrs) do
    # The provider is the page's, never the hidden form field: creating a key
    # under another provider would hand it the operator's secret.
    attrs = Map.put(attrs, "provider_id", socket.assigns.provider.id)

    case Providers.create_credential(attrs) do
      {:ok, credential} ->
        audit(socket, "credential.create", "credential", credential.id, %{
          "provider_id" => credential.provider_id,
          "name" => credential.name
        })

        socket
        |> put_flash(:info, "Credencial creada.")
        |> close_credential_form()
        |> load_keys()

      {:error, changeset} ->
        assign(socket, :credential_form, to_form(changeset, as: :credential))
    end
  end

  defp update_credential(socket, credential, attrs) do
    # A blank secret on edit means "keep the current one": the field is dropped
    # instead of cast, so an empty submit never overwrites the stored key.
    rotated? = present?(attrs["api_key_encrypted"])
    attrs = if rotated?, do: attrs, else: Map.drop(attrs, ["api_key_encrypted"])

    case Providers.update_credential(credential, attrs) do
      {:ok, updated} ->
        audit(socket, "credential.update", "credential", updated.id, %{
          "provider_id" => updated.provider_id,
          "name" => updated.name,
          "key_rotated" => rotated?
        })

        socket
        |> put_flash(:info, "Credencial actualizada.")
        |> close_credential_form()
        |> load_keys()

      {:error, changeset} ->
        assign(socket, :credential_form, to_form(changeset, as: :credential))
    end
  end

  # Credentials in "error" state cannot be toggled — they must be reactivated.
  defp toggle_credential(socket, %Credential{status: "error"}) do
    put_flash(socket, :error, gettext("This credential is in error. Use Reactivate."))
  end

  defp toggle_credential(socket, credential) do
    new_status = if credential.status == "active", do: "disabled", else: "active"

    case Providers.update_credential(credential, %{status: new_status}) do
      {:ok, _} ->
        audit(socket, "credential.toggle_status", "credential", credential.id, %{
          "provider_id" => credential.provider_id,
          "name" => credential.name,
          "status" => new_status
        })

        socket
        |> put_flash(
          :info,
          "Credencial #{if(new_status == "active", do: "activada", else: "desactivada")}."
        )
        |> load_keys()

      {:error, _} ->
        put_flash(socket, :error, gettext("Could not update the credential."))
    end
  end

  defp reactivate_credential(socket, %Credential{status: "error"} = credential) do
    case Providers.reactivate_credential(credential) do
      {:ok, _} ->
        audit(socket, "credential.reactivate", "credential", credential.id, %{
          "provider_id" => credential.provider_id,
          "name" => credential.name
        })

        socket
        |> put_flash(:info, "Credencial reactivada.")
        |> load_keys()

      {:error, _} ->
        put_flash(socket, :error, gettext("Could not reactivate the credential."))
    end
  end

  defp reactivate_credential(socket, _credential) do
    put_flash(socket, :error, gettext("Only credentials in error can be reactivated."))
  end

  defp reset_breaker(socket, credential) do
    Tokengate.Routing.CircuitBreakerManager.reset(credential.id)

    audit(socket, "credential.breaker_reset", "credential", credential.id, %{
      "provider_id" => credential.provider_id,
      "name" => credential.name
    })

    socket
    |> put_flash(:info, "Circuit breaker reseteado.")
    |> load_keys()
  end

  defp delete_credential(socket, credential) do
    case Providers.delete_credential(credential) do
      {:ok, _} ->
        audit(socket, "credential.delete", "credential", credential.id, %{
          "provider_id" => credential.provider_id,
          "name" => credential.name
        })

        socket
        |> put_flash(:info, "Credencial eliminada.")
        |> load_keys()

      {:error, :credential_in_pool} ->
        # The membership is part of a lane's credential source (RESTRICT
        # FK): deleting the key would leave the pool smaller than the operator
        # thinks. It is refused with a message, not with a 500.
        put_flash(
          socket,
          :error,
          gettext("This API key belongs to a pool. Remove it from the pool first.")
        )

      {:error, _} ->
        put_flash(socket, :error, gettext("Could not delete the credential."))
    end
  end

  ## Private helpers -------------------------------------------------------

  defp with_credential(socket, cred_id, fun) do
    case fetch_credential(socket, cred_id) do
      {:ok, credential} -> {:noreply, fun.(socket, credential)}
      :error -> {:noreply, credential_missing(socket)}
    end
  end

  # Resolves a credential id against THIS page's provider. The cast happens
  # first because `Repo.get/2` raises `Ecto.Query.CastError` on a non-UUID id;
  # ownership is checked here so no handler can be pointed at another
  # provider's key. Missing and foreign ids answer the same way on purpose: the
  # client learns nothing about keys it cannot see.
  defp fetch_credential(socket, cred_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(cred_id),
         %Credential{provider_id: provider_id} = credential <-
           Providers.get_credential(uuid),
         true <- provider_id == socket.assigns.provider.id do
      {:ok, credential}
    else
      _ -> :error
    end
  end

  defp credential_missing(socket) do
    put_flash(socket, :error, gettext("This API key does not belong to this provider."))
  end

  # The edit form is built from the row with the secret field cleared: the
  # stored key never reaches the DOM. `update_credential/3` rebuilds the
  # changeset from the submitted params, so clearing it here cannot erase the
  # stored secret — a blank field keeps the current key (and the password input
  # drops `value` on top of this, see `CoreComponents.input/1`).
  defp edit_changeset(credential) do
    credential
    |> Providers.change_credential()
    |> Ecto.Changeset.force_change(:api_key_encrypted, nil)
  end

  defp close_credential_form(socket) do
    socket
    |> assign(:credential_form, nil)
    |> assign(:editing_credential_id, nil)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # `?new=1` opens the alta modal on arrival: activating a catalog provider in the
  # index navigates here with that flag, so the operator lands one keystroke
  # away from typing the secret instead of having to find the button.
  defp open_new_credential_form(socket, true) do
    changeset =
      Providers.change_credential(%Credential{
        provider_id: socket.assigns.provider.id,
        status: "active"
      })

    socket
    |> assign(:credential_form, to_form(changeset, as: :credential))
    |> assign(:editing_credential_id, nil)
  end

  defp open_new_credential_form(socket, _flag), do: socket

  @doc "Mask an api key for display: show only the last 4 chars."
  def mask_key(nil), do: "—"
  def mask_key(""), do: "—"
  def mask_key(key) when byte_size(key) <= 4, do: "****"

  def mask_key(key) do
    len = String.length(key)

    String.slice(key, len - 4, 4)
    |> then(&"••••••#{&1}")
  end

  @doc "Human-readable label for circuit breaker state."
  def breaker_label(:closed), do: gettext("Closed")
  def breaker_label(:open), do: gettext("Open")
  def breaker_label(:half_open), do: "Half-Open"
  def breaker_label(_), do: "—"

  @doc "Human-readable label for the lifecycle status of a credential."
  def credential_status_label("active"), do: gettext("Active")
  def credential_status_label("disabled"), do: gettext("Disabled")
  def credential_status_label("error"), do: gettext("Error")
  def credential_status_label(_), do: "—"

  @doc """
  Badge class for the lifecycle status of a credential: error is red (the key
  was rejected upstream and needs Reactivate), disabled is muted, active green.
  """
  def credential_status_class("error"), do: "badge-error"
  def credential_status_class("disabled"), do: "badge-warning"
  def credential_status_class(_), do: "badge-success"

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
          {gettext("API keys")}
          <:subtitle>
            <span class="font-medium text-base-content">{@provider.name}</span>
            · <code class="font-mono">{@provider.base_url}</code>
          </:subtitle>
          <:actions>
            <div class="flex flex-wrap items-center gap-2">
              <.link
                navigate={~p"/catalog/providers"}
                class="btn btn-ghost btn-sm"
                id="back-to-providers"
              >
                <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Providers")}
              </.link>
              <.button
                phx-click="new_credential"
                phx-value-provider_id={@provider.id}
                id={"new-credential-#{@provider.id}"}
                class="btn btn-primary btn-soft btn-sm"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("API key")}
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- Provider-level limits: every key below inherits them; operators can
             tune them inline via the Edit button. --%>
        <div class="flex flex-wrap items-center gap-1.5" id="keys-provider-limits">
          <span class="text-[10px] uppercase tracking-wide text-base-content/40">
            {gettext("Inherited limits")}
          </span>
          <span class="badge badge-ghost badge-sm" title={gettext("Requests per minute")}>
            RPM {@provider.max_rpm || "∞"}
          </span>
          <span class="badge badge-ghost badge-sm" title={gettext("Provider max concurrency")}>
            Conc. {@provider.max_concurrent || "∞"}
          </span>
          <span class="badge badge-ghost badge-sm" title={gettext("Max concurrency per user")}>
            {gettext("Conc./user")} {@provider.max_concurrent_per_user || "∞"}
          </span>
          <span class="badge badge-ghost badge-sm font-mono" title={gettext("Receive timeout")}>
            {Tokengate.Providers.ProviderLimits.receive_timeout_ms(@provider)} ms
          </span>
          <button
            type="button"
            phx-click="edit_provider_limits"
            class="btn btn-xs btn-ghost ml-1"
            id="edit-provider-limits"
            title={gettext("Edit inherited limits")}
          >
            <.icon name="hero-pencil-square" class="w-3.5 h-3.5" /> {gettext("Edit")}
          </button>
        </div>

        <.modal
          :if={@limits_form}
          id="provider-limits-modal"
          title={gettext("Provider limits")}
          on_close="cancel_provider_limits"
          max_w="max-w-2xl"
        >
          <p class="text-xs text-base-content/50 mb-3">
            {gettext(
              "They apply to every API key of this provider, which inherits them. Empty = no limit."
            )}
          </p>
          <.form for={@limits_form} id="provider-limits-form" phx-submit="save_provider_limits">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-5">
              <.input
                field={@limits_form[:max_rpm]}
                type="number"
                label="Max RPM"
                hint={gettext("Requests per minute across the provider. Empty = no limit.")}
              />
              <.input
                field={@limits_form[:max_concurrent]}
                type="number"
                label={gettext("Max concurrency")}
                hint={gettext("Concurrent requests across the provider. Empty = no limit.")}
              />
              <.input
                field={@limits_form[:max_concurrent_per_user]}
                type="number"
                label={gettext("Max concurrency per user")}
                hint={gettext("Concurrent cap per user. Empty = no limit.")}
              />
              <.input
                field={@limits_form[:receive_timeout_ms]}
                type="number"
                label="Timeout (ms)"
                hint={
                  gettext("Max wait per response. Empty = global default (%{ms} ms).",
                    ms: Tokengate.Providers.ProviderLimits.default_receive_timeout_ms()
                  )
                }
              />
            </div>
            <div class="flex gap-2 pt-4 mt-5 border-t border-base-200 justify-end">
              <button
                type="button"
                phx-click="cancel_provider_limits"
                class="btn btn-ghost btn-sm"
                id="cancel-provider-limits-btn"
              >
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary btn-sm" id="save-provider-limits-btn">
                {gettext("Save")}
              </button>
            </div>
          </.form>
        </.modal>

        <%!-- Credential form (create / edit) — modal --%>
        <.modal
          :if={@credential_form}
          id="credential-form-modal"
          title={
            if @editing_credential_id,
              do: gettext("Edit credential"),
              else: gettext("New credential")
          }
          on_close="cancel_credential"
          max_w="max-w-2xl"
        >
          <.form for={@credential_form} id="credential-form" phx-submit="save_credential">
            <.input field={@credential_form[:provider_id]} type="hidden" />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-5">
              <.input
                field={@credential_form[:name]}
                type="text"
                label="Alias"
                placeholder={gettext("Production")}
                hint={gettext("Name to identify this credential.")}
              />
              <.input
                field={@credential_form[:api_key_encrypted]}
                type="password"
                label={"#{gettext("API key")}#{if @editing_credential_id, do: gettext(" (leave empty = unchanged)"), else: ""}"}
                placeholder={
                  if @editing_credential_id,
                    do: gettext("sk-... (leave empty to keep)"),
                    else: "sk-..."
                }
                hint={
                  if @editing_credential_id,
                    do: gettext("Only if you want to change it."),
                    else: gettext("The token the provider gives you (sk-...).")
                }
              />
            </div>
            <div class="flex gap-2 pt-4 mt-5 border-t border-base-200 justify-end">
              <button type="button" phx-click="cancel_credential" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary btn-sm" id="save-credential-btn">
                {(@editing_credential_id && gettext("Update")) || gettext("Save")}
              </button>
            </div>
          </.form>
        </.modal>

        <%!-- Las keys de ESTE proveedor, en tabla: alias, secreto enmascarado,
             modelos, tráfico y breaker. El secreto NUNCA se renderiza
             completo: `mask_key/1` deja solo los últimos 4 caracteres. --%>
        <div
          class="card bg-base-100 border border-base-300 shadow-sm overflow-x-auto"
          id={"keys-panel-#{@provider.id}"}
        >
          <.table
            id="keys-table"
            rows={@credentials}
            row_id={fn cred -> "credential-#{cred.id}" end}
            row_class="align-top"
          >
            <:col :let={cred} label={gettext("Alias")}>
              <div id={"credential-alias-#{cred.id}"}>
                <p class="font-medium text-sm">{cred.name || "—"}</p>
                <span class={["badge badge-xs mt-1", credential_status_class(cred.status)]}>
                  {credential_status_label(cred.status)}
                </span>
              </div>
            </:col>
            <:col :let={cred} label={gettext("Key")}>
              <code class="text-sm font-mono">{mask_key(cred.api_key_encrypted)}</code>
            </:col>
            <:col :let={cred} label={gettext("Models")} align="right">
              <span class="badge badge-ghost badge-sm">
                {Map.get(@credential_model_counts, cred.id, 0)}
              </span>
            </:col>
            <:col :let={cred} label={gettext("In flight")} align="right">
              <% inflight = Map.get(@credential_inflight, cred.id, 0) %>
              <span class={[
                "badge badge-sm",
                if(inflight > 0, do: "badge-primary", else: "badge-ghost")
              ]}>
                {inflight}
              </span>
            </:col>
            <:col :let={cred} label={gettext("Breaker")}>
              <% breaker = Map.get(@breaker_statuses, cred.id, :closed) %>
              <div class="flex items-center gap-2">
                <span
                  class={[
                    "badge badge-sm",
                    breaker == :closed && "badge-success",
                    breaker == :open && "badge-error",
                    breaker == :half_open && "badge-warning"
                  ]}
                  id={"credential-breaker-#{cred.id}"}
                >
                  {breaker_label(breaker)}
                </span>
                <button
                  :if={breaker != :closed}
                  phx-click="reset_breaker"
                  phx-value-id={cred.id}
                  class="btn btn-xs btn-ghost"
                  id={"reset-breaker-#{cred.id}"}
                  title={gettext("Reset circuit breaker")}
                  aria-label={gettext("Reset circuit breaker")}
                >
                  <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Reset")}
                </button>
              </div>
            </:col>
            <:action :let={cred}>
              <%= if cred.status == "error" do %>
                <button
                  phx-click="reactivate_credential"
                  phx-value-id={cred.id}
                  class="btn btn-xs btn-ghost text-warning"
                  id={"reactivate-credential-#{cred.id}"}
                  title={gettext("Reactivate")}
                  aria-label={gettext("Reactivate")}
                >
                  <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
                </button>
              <% else %>
                <button
                  phx-click="toggle_credential"
                  phx-value-id={cred.id}
                  class="btn btn-xs btn-ghost"
                  id={"toggle-credential-btn-#{cred.id}"}
                  title={
                    if cred.status == "active",
                      do: gettext("Disable"),
                      else: gettext("Enable")
                  }
                  aria-label={
                    if cred.status == "active",
                      do: gettext("Disable"),
                      else: gettext("Enable")
                  }
                >
                  <.icon
                    name={if cred.status == "active", do: "hero-pause", else: "hero-play"}
                    class="w-3.5 h-3.5"
                  />
                </button>
              <% end %>
              <button
                phx-click="edit_credential"
                phx-value-id={cred.id}
                class="btn btn-xs btn-ghost"
                id={"edit-credential-#{cred.id}"}
                title={gettext("Edit")}
                aria-label={gettext("Edit")}
              >
                <.icon name="hero-pencil-square" class="w-3.5 h-3.5" />
              </button>
              <button
                phx-click="delete_credential"
                phx-value-id={cred.id}
                data-confirm={gettext("Delete this credential?")}
                class="btn btn-xs btn-ghost text-error"
                id={"delete-credential-#{cred.id}"}
                title={gettext("Delete")}
                aria-label={gettext("Delete")}
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" />
              </button>
            </:action>
            <:empty>
              <div id="keys-empty">
                <.icon name="hero-key" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                <p>{gettext("This provider has no API keys yet.")}</p>
              </div>
            </:empty>
          </.table>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
