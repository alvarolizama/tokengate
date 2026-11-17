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
  def mount(%{"id" => provider_id} = params, _session, socket) do
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
          |> assign(:editing_credential_id, nil)
          |> assign(:is_admin, user && user.global_role == "admin")
          |> assign(:credential_inflight, %{})
          |> require_admin_hook()
          |> load_keys()
          |> open_new_credential_form(params["new"] == "1")

        {:ok, socket}
    end
  end

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

  defp assign_inflight(socket) do
    credential_counts =
      Tokengate.Logs.Inflight.count_by_credential()
      |> Map.new(fn %{credential_id: id, count: n} -> {id, n} end)

    assign(socket, :credential_inflight, credential_counts)
  end

  ## Live in-flight refresh -------------------------------------------------

  @impl true
  def handle_info({:inflight_started, _entry}, socket) do
    {:noreply, assign_inflight(socket)}
  end

  def handle_info({:inflight_done, _id}, socket) do
    {:noreply, assign_inflight(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events — credential management ----------------------------------------

  @impl true
  def handle_event("new_credential", _params, socket) do
    {:noreply, open_new_credential_form(socket, true)}
  end

  def handle_event("edit_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)
    changeset = Providers.change_credential(cred)

    {:noreply,
     socket
     |> assign(:credential_form, to_form(changeset, as: :credential))
     |> assign(:editing_credential_id, cred.id)}
  end

  def handle_event("cancel_credential", _params, socket) do
    {:noreply, socket |> assign(:credential_form, nil) |> assign(:editing_credential_id, nil)}
  end

  def handle_event("save_credential", %{"credential" => cred_params}, socket) do
    editing_id = socket.assigns[:editing_credential_id]

    if editing_id do
      cred = Providers.get_credential!(editing_id)

      # Si el api_key viene vacío, evitamos sobrescribir — lo removemos
      cred_params =
        if cred_params["api_key_encrypted"] in [nil, ""] do
          Map.drop(cred_params, ["api_key_encrypted"])
        else
          cred_params
        end

      case Providers.update_credential(cred, cred_params) do
        {:ok, _cred} ->
          audit(socket, "credential.update", "credential", cred.id, %{
            "provider_id" => cred.provider_id,
            "name" => cred.name,
            "key_rotated" => Map.has_key?(cred_params, "api_key_encrypted")
          })

          {:noreply,
           socket
           |> put_flash(:info, "Credencial actualizada.")
           |> assign(:credential_form, nil)
           |> assign(:editing_credential_id, nil)
           |> load_keys()}

        {:error, changeset} ->
          {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}
      end
    else
      case Providers.create_credential(cred_params) do
        {:ok, cred} ->
          audit(socket, "credential.create", "credential", cred.id, %{
            "provider_id" => cred.provider_id,
            "name" => cred.name
          })

          {:noreply,
           socket
           |> put_flash(:info, "Credencial creada.")
           |> assign(:credential_form, nil)
           |> assign(:editing_credential_id, nil)
           |> load_keys()}

        {:error, changeset} ->
          {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}
      end
    end
  end

  def handle_event("toggle_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    # Credentials in "error" state cannot be toggled — they must be reactivated.
    if cred.status == "error" do
      {:noreply,
       put_flash(socket, :error, gettext("This credential is in error. Use Reactivate."))}
    else
      new_status = if cred.status == "active", do: "disabled", else: "active"

      case Providers.update_credential(cred, %{status: new_status}) do
        {:ok, _} ->
          audit(socket, "credential.toggle_status", "credential", cred.id, %{
            "provider_id" => cred.provider_id,
            "name" => cred.name,
            "status" => new_status
          })

          {:noreply,
           socket
           |> put_flash(
             :info,
             "Credencial #{if(new_status == "active", do: "activada", else: "desactivada")}."
           )
           |> load_keys()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the credential."))}
      end
    end
  end

  def handle_event("reactivate_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    if cred.status == "error" do
      case Providers.reactivate_credential(cred) do
        {:ok, _} ->
          audit(socket, "credential.reactivate", "credential", cred.id, %{
            "provider_id" => cred.provider_id,
            "name" => cred.name
          })

          {:noreply,
           socket
           |> put_flash(:info, "Credencial reactivada.")
           |> load_keys()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not reactivate the credential."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only credentials in error can be reactivated."))}
    end
  end

  def handle_event("reset_breaker", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    Tokengate.Routing.CircuitBreakerManager.reset(cred.id)

    audit(socket, "credential.breaker_reset", "credential", cred.id, %{
      "provider_id" => cred.provider_id,
      "name" => cred.name
    })

    {:noreply,
     socket
     |> put_flash(:info, "Circuit breaker reseteado.")
     |> load_keys()}
  end

  def handle_event("delete_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    case Providers.delete_credential(cred) do
      {:ok, _} ->
        audit(socket, "credential.delete", "credential", cred.id, %{
          "provider_id" => cred.provider_id,
          "name" => cred.name
        })

        {:noreply,
         socket
         |> put_flash(:info, "Credencial eliminada.")
         |> load_keys()}

      {:error, :credential_in_pool} ->
        # La membresía es parte de la fuente de credenciales de un lane (FK
        # RESTRICT): borrar la key dejaría el pool más chico de lo que el
        # operador cree. Se rechaza con mensaje, no con un 500.
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This API key belongs to a pool. Remove it from the pool first.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the credential."))}
    end
  end

  ## Private helpers -------------------------------------------------------

  # `?new=1` opens the alta modal on mount: activating a catalog provider in the
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

  @doc """
  Row highlight class for credentials that need attention: error status,
  open/half-open circuit breaker (red), or manually disabled (muted).
  """
  def credential_row_class(%Credential{status: "error"}, _breaker),
    do: "bg-error/10 hover:bg-error/20"

  def credential_row_class(_cred, breaker) when breaker in [:open, :half_open],
    do: "bg-error/10 hover:bg-error/20"

  def credential_row_class(%Credential{status: "disabled"}, _breaker),
    do: "bg-warning/10 hover:bg-warning/20"

  def credential_row_class(_cred, _breaker), do: nil

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
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("API key")}
            </.button>
          </:actions>
        </.header>

        <%!-- Provider-level limits: every key below inherits them, so they are
             read-only here and edited in the providers table. --%>
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
          <.link
            navigate={~p"/catalog/providers"}
            class="text-xs link link-hover ml-1"
            id="edit-provider-limits"
          >
            {gettext("Edit")}
          </.link>
        </div>

        <%!-- Credential form (create / edit) — modal --%>
        <div :if={@credential_form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_credential" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_credential_id,
                  do: gettext("Edit credential"),
                  else: gettext("New credential")}
              </h2>
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
            </div>
          </div>
        </div>

        <div
          :if={@credentials == []}
          class="text-center py-12 text-base-content/40"
          id="keys-empty"
        >
          <.icon name="hero-key" class="w-10 h-10 mx-auto mb-2 opacity-40" />
          <p>{gettext("This provider has no API keys yet.")}</p>
        </div>

        <div
          :if={@credentials != []}
          class="card bg-base-100 border border-base-300 shadow-sm overflow-x-auto"
          id={"keys-panel-#{@provider.id}"}
        >
          <table class="table table-sm" id="keys-table">
            <thead>
              <tr>
                <th>{gettext("Alias")}</th>
                <th>{gettext("Key")}</th>
                <th>{gettext("Models")}</th>
                <th>{gettext("In flight")}</th>
                <th>{gettext("Breaker")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={cred <- @credentials}
                id={"credential-#{cred.id}"}
                class={credential_row_class(cred, Map.get(@breaker_statuses, cred.id, :closed))}
              >
                <td>
                  {cred.name || "—"}
                </td>
                <td>
                  <code class="text-sm font-mono">{mask_key(cred.api_key_encrypted)}</code>
                </td>
                <td>
                  <span class="badge badge-ghost badge-sm">
                    {Map.get(@credential_model_counts, cred.id, 0)}
                  </span>
                </td>
                <td>
                  <% inflight = Map.get(@credential_inflight, cred.id, 0) %>
                  <span class={[
                    "badge badge-sm",
                    if(inflight > 0, do: "badge-primary", else: "badge-ghost")
                  ]}>
                    {inflight}
                  </span>
                </td>
                <td>
                  <% breaker = Map.get(@breaker_statuses, cred.id, :closed) %>
                  <div class="flex items-center gap-2">
                    <span class={[
                      "badge badge-sm",
                      breaker == :closed && "badge-success",
                      breaker == :open && "badge-error",
                      breaker == :half_open && "badge-warning"
                    ]}>
                      {breaker_label(breaker)}
                    </span>
                    <button
                      :if={breaker != :closed}
                      phx-click="reset_breaker"
                      phx-value-id={cred.id}
                      class="btn btn-xs btn-ghost"
                      id={"reset-breaker-#{cred.id}"}
                    >
                      <.icon name="hero-arrow-path" class="w-3 h-3" /> Reset
                    </button>
                  </div>
                </td>
                <td class="text-right">
                  <%= if cred.status == "error" do %>
                    <button
                      phx-click="reactivate_credential"
                      phx-value-id={cred.id}
                      class="btn btn-xs btn-ghost btn-warning"
                      id={"reactivate-credential-#{cred.id}"}
                    >
                      <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Reactivate")}
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
                    >
                      <.icon
                        name={if cred.status == "active", do: "hero-pause", else: "hero-play"}
                        class="w-3 h-3"
                      />
                    </button>
                  <% end %>
                  <button
                    phx-click="edit_credential"
                    phx-value-id={cred.id}
                    class="btn btn-xs btn-ghost"
                    id={"edit-credential-#{cred.id}"}
                  >
                    <.icon name="hero-pencil-square" class="w-3 h-3" /> {gettext("Edit")}
                  </button>
                  <button
                    phx-click="delete_credential"
                    phx-value-id={cred.id}
                    data-confirm={gettext("Delete this credential?")}
                    class="btn btn-xs btn-ghost text-error"
                    id={"delete-credential-#{cred.id}"}
                  >
                    {gettext("Delete")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
