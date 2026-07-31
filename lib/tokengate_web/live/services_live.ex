defmodule TokengateWeb.ServicesLive do
  @moduledoc """
  Admin-only CRUD for services + per-service model alias grants.

  Services are API keys not tied to a user. They have direct limits
  (monthly budget, concurrency, RPM) without the team/member hierarchy.
  """
  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Accounts.Service
  alias Tokengate.Providers
  alias Tokengate.Providers.{ModelAlias, ServiceModelAlias}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user.global_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, "No tienes permisos para acceder a esta sección.")
       |> redirect(to: "/dashboard")}
    else
      socket =
        socket
        |> assign(:page_title, "Servicios · Tokengate")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:form, nil)
        |> assign(:editing_service_id, nil)
        |> assign(:new_token, nil)
        |> assign(:new_token_service_id, nil)
        |> load_services()

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

  defp load_services(socket) do
    services =
      from(s in Service,
        preload: [:api_key],
        order_by: [asc: s.name]
      )
      |> Repo.all()

    granted_aliases =
      from(sma in ServiceModelAlias, select: {sma.service_id, sma.model_alias_id})
      |> Repo.all()
      |> Enum.group_by(fn {service_id, _} -> service_id end, fn {_, alias_id} -> alias_id end)

    aliases =
      from(ma in ModelAlias, order_by: [asc: ma.name])
      |> Repo.all()

    # Load monthly stats per service (team_member_id = service_id for services)
    service_ids = Enum.map(services, & &1.id)
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)

    stats =
      from(l in Tokengate.Logs.RequestLog,
        where: l.team_member_id in ^service_ids,
        where: l.inserted_at >= ^thirty_days_ago,
        group_by: l.team_member_id,
        select: %{
          service_id: l.team_member_id,
          total_cost: sum(l.provider_cost_usd),
          total_requests: count(l.id),
          total_input_tokens: sum(l.prompt_tokens),
          total_output_tokens: sum(l.completion_tokens),
          avg_latency_ms: avg(l.latency_ms)
        }
      )
      |> Repo.all()
      |> Map.new(fn s -> {s.service_id, s} end)

    socket
    |> stream(:services, services, reset: true)
    |> assign(:services_empty?, services == [])
    |> assign(:granted_aliases, granted_aliases)
    |> assign(:aliases, aliases)
    |> assign(:service_stats, stats)
  end

  ## Events — service CRUD ------------------------------------------------

  @impl true
  def handle_event("new_service", _params, socket) do
    changeset = Accounts.change_service(%Service{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :service))
     |> assign(:editing_service_id, :new)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_service_id, nil)}
  end

  def handle_event("edit_service", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)
    changeset = Accounts.change_service(service)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :service))
     |> assign(:editing_service_id, service.id)}
  end

  def handle_event("save_service", %{"service" => service_params}, socket) do
    save_service(socket, socket.assigns.editing_service_id, service_params)
  end

  def handle_event("delete_service", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)

    case Accounts.delete_service(service) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Servicio eliminado.")
         |> load_services()}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field} #{message}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, "No se pudo eliminar: #{msg}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo eliminar el servicio.")}
    end
  end

  ## Events — API key management -----------------------------------------

  def handle_event("generate_key", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)

    case Accounts.generate_service_api_key(service) do
      {:ok, _api_key, new_token} ->
        {:noreply,
         socket
         |> assign(:new_token, new_token)
         |> assign(:new_token_service_id, service_id)
         |> put_flash(:info, "Clave generada correctamente.")
         |> load_services()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo generar la clave.")}
    end
  end

  def handle_event("revoke_key", %{"id" => service_id}, socket) do
    service = Accounts.get_service!(service_id)

    service =
      if service.api_key do
        Repo.preload(service, :api_key)
      else
        service
      end

    case service.api_key do
      nil ->
        {:noreply, put_flash(socket, :error, "Este servicio no tiene clave.")}

      api_key ->
        case Accounts.revoke_service_api_key(api_key) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Clave revocada.")
             |> load_services()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
        end
    end
  end

  def handle_event("dismiss_new_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  ## Events — alias grants -----------------------------------------------

  def handle_event("toggle_alias", %{"service-id" => service_id, "alias-id" => alias_id}, socket) do
    service_alias_ids = Map.get(socket.assigns.granted_aliases, service_id, [])

    result =
      if alias_id in service_alias_ids do
        Providers.revoke_alias_from_service(service_id, alias_id)
      else
        Providers.grant_alias_to_service(service_id, alias_id)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Aliases actualizados.")
         |> load_services()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo actualizar el alias.")}
    end
  end

  ## Private helpers — save ----------------------------------------------

  defp save_service(socket, :new, service_params) do
    case Accounts.create_service(service_params) do
      {:ok, _service} ->
        {:noreply,
         socket
         |> put_flash(:info, "Servicio creado.")
         |> assign(:form, nil)
         |> assign(:editing_service_id, nil)
         |> load_services()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :service))}
    end
  end

  defp save_service(socket, service_id, service_params) when is_binary(service_id) do
    service = Accounts.get_service!(service_id)

    case Accounts.update_service(service, service_params) do
      {:ok, _service} ->
        {:noreply,
         socket
         |> put_flash(:info, "Servicio actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_service_id, nil)
         |> load_services()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :service))}
    end
  end

  ## Template helpers -----------------------------------------------------

  def granted_alias_ids(granted_aliases, service_id) do
    Map.get(granted_aliases, service_id, [])
  end

  def format_decimal(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  def format_decimal(nil), do: "—"
  def format_decimal(value), do: to_string(value)

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(%Decimal{} = d),
    do: d |> Decimal.round(0) |> Decimal.to_string() |> format_number()

  def format_number(nil), do: "0"
  def format_number(n), do: to_string(n)

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Servicios
          <:subtitle>API keys para servicios sin usuario asociado</:subtitle>
          <:actions>
            <.button phx-click="new_service" id="new-service-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo servicio
            </.button>
          </:actions>
        </.header>

        <%!-- New token banner --%>
        <div
          :if={@new_token}
          class="alert alert-success"
          id="new-token-banner"
        >
          <.icon name="hero-key" class="w-5 h-5 shrink-0" />
          <div>
            <p class="font-semibold">Clave generada</p>
            <p class="text-sm opacity-80">Cópiala ahora, no se volverá a mostrar.</p>
            <code class="block mt-2 p-2 bg-black/10 rounded text-sm font-mono break-all">
              {@new_token}
            </code>
          </div>
          <button phx-click="dismiss_new_token" class="btn btn-ghost btn-sm">
            Cerrar
          </button>
        </div>

        <%!-- Service form (create / edit) — modal --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_service_id == :new, do: "Nuevo servicio", else: "Editar servicio"}
              </h2>
              <.form for={@form} id="service-form" phx-submit="save_service">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Nombre"
                  hint={"Nombre identificativo del servicio. Ej.: \"Bot de Telegram\", \"Webhook de Shopify\"."}
                />
                <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                  <.input
                    field={@form[:monthly_budget_usd]}
                    type="number"
                    label="Budget mensual (USD)"
                    step="any"
                    hint="Presupuesto mensual. Vacío = sin límite."
                  />
                  <.input
                    field={@form[:concurrency_limit]}
                    type="number"
                    label="Concurrencia"
                    hint="Peticiones simultáneas."
                  />
                  <.input
                    field={@form[:rpm_limit]}
                    type="number"
                    label="RPM"
                    hint="Requests por minuto."
                  />
                </div>
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-service-btn">Guardar</button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <div id="services" phx-update="stream">
          <div
            :if={@services_empty?}
            class="text-center py-12 text-base-content/40"
            id="services-empty"
          >
            <.icon name="hero-wrench-screwdriver" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p>No hay servicios todavía.</p>
          </div>
          <div
            :for={{id, service} <- @streams.services}
            id={id}
            class="card bg-base-100 border border-base-300 shadow-sm mb-4 transition-shadow hover:shadow-md"
          >
            <div class="card-body">
              <div class="flex items-start justify-between">
                <div>
                  <h3 class="font-semibold text-base-content">{service.name}</h3>
                  <div class="flex flex-wrap gap-2 mt-2">
                    <span class="badge badge-outline badge-sm">
                      {format_decimal(service.monthly_budget_usd)} USD/mes
                    </span>
                    <span class="badge badge-outline badge-sm">
                      {service.concurrency_limit} conc.
                    </span>
                    <span class="badge badge-outline badge-sm">
                      {service.rpm_limit} RPM
                    </span>
                  </div>
                </div>
                <div class="flex gap-1">
                  <button
                    phx-click="edit_service"
                    phx-value-id={service.id}
                    class="btn btn-ghost btn-xs"
                    title="Editar"
                  >
                    <.icon name="hero-pencil" class="w-4 h-4" />
                  </button>
                  <button
                    phx-click="delete_service"
                    phx-value-id={service.id}
                    data-confirm="¿Eliminar este servicio? Se perderán la clave y los aliases."
                    class="btn btn-ghost btn-xs text-error"
                    title="Eliminar"
                  >
                    <.icon name="hero-trash" class="w-4 h-4" />
                  </button>
                </div>
              </div>

              <% has_activity = Map.get(@service_stats, service.id) != nil %>
              <% stats =
                Map.get(@service_stats, service.id, %{
                  total_cost: Decimal.new(0),
                  total_requests: 0,
                  total_input_tokens: 0,
                  total_output_tokens: 0
                }) %>
              <div class="mt-3 grid grid-cols-4 gap-3">
                <%!-- Gasto real --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Gasto real
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-success/10">
                        <.icon name="hero-currency-dollar" class="w-4 h-4 text-success" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      ${format_decimal(stats.total_cost || 0)}
                    </p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>

                <%!-- Requests --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Requests
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-primary/10">
                        <.icon name="hero-bolt" class="w-4 h-4 text-primary" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {format_number(stats.total_requests || 0)}
                    </p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>

                <%!-- Tokens In --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Tokens In
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-accent/10">
                        <.icon name="hero-arrow-down-tray" class="w-4 h-4 text-accent" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {format_number(stats.total_input_tokens || 0)}
                    </p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>

                <%!-- Tokens Out --%>
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                        Tokens Out
                      </span>
                      <span class="flex items-center justify-center w-8 h-8 rounded-lg bg-warning/10">
                        <.icon name="hero-arrow-up-tray" class="w-4 h-4 text-warning" />
                      </span>
                    </div>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {format_number(stats.total_output_tokens || 0)}
                    </p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>
              </div>
              <%= if !has_activity do %>
                <p class="text-xs text-base-content/40 mt-2">
                  Sin actividad en los últimos 30 días
                </p>
              <% end %>

              <%!-- API Key section --%>
              <div class="mt-4 p-3 bg-base-200 rounded-lg">
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-sm font-medium">API Key</p>
                    <%= if service.api_key do %>
                      <p class="text-xs text-base-content/60">
                        <span class="font-mono">{service.api_key.key_prefix}</span>…
                        <span class={[
                          "badge badge-xs",
                          if(service.api_key.status == "active",
                            do: "badge-success",
                            else: "badge-error"
                          )
                        ]}>
                          {service.api_key.status}
                        </span>
                      </p>
                    <% else %>
                      <p class="text-xs text-base-content/40">Sin clave</p>
                    <% end %>
                  </div>
                  <div class="flex gap-1">
                    <button
                      phx-click="generate_key"
                      phx-value-id={service.id}
                      class="btn btn-primary btn-xs"
                      title={if service.api_key, do: "Regenerar clave", else: "Generar clave"}
                    >
                      <.icon name="hero-key" class="w-4 h-4" />
                      {if service.api_key, do: "Regenerar", else: "Generar"}
                    </button>
                    <%= if service.api_key && service.api_key.status == "active" do %>
                      <button
                        phx-click="revoke_key"
                        phx-value-id={service.id}
                        data-confirm="¿Revocar esta clave? El servicio dejará de funcionar inmediatamente."
                        class="btn btn-error btn-xs"
                        title="Revocar clave"
                      >
                        <.icon name="hero-no-symbol" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Model aliases section --%>
              <div class="mt-4">
                <p class="text-sm font-medium mb-2">Modelos permitidos</p>
                <div class="flex flex-wrap gap-2">
                  <button
                    :for={alias <- @aliases}
                    phx-click="toggle_alias"
                    phx-value-service-id={service.id}
                    phx-value-alias-id={alias.id}
                    class={[
                      "badge badge-sm cursor-pointer transition-all",
                      if(alias.id in granted_alias_ids(@granted_aliases, service.id),
                        do: "badge-primary",
                        else: "badge-outline"
                      )
                    ]}
                  >
                    {alias.name}
                  </button>
                  <%= if @aliases == [] do %>
                    <p class="text-xs text-base-content/40">No hay aliases configurados</p>
                  <% end %>
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
