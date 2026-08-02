defmodule TokengateWeb.SupervisedServicesLive do
  @moduledoc """
  Read-only view of the services the current user supervises.

  Supervisors need visibility into spend, request volume, tokens, latency,
  and current API-key / alias configuration for the services they own —
  but they must NOT be able to mutate anything. All admin actions
  (create / edit / delete / regenerate key / revoke key / toggle alias)
  live exclusively in `TokengateWeb.ServicesLive` behind the `:admin`
  live_session.

  Intentionally NOT defined: any `handle_event/3` callback. The view is
  pure display — even if a malicious client fired a `phx-click` event
  directly at the WebSocket, it would simply error because no handler is
  attached.
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Periods
  alias Tokengate.Providers.{ModelAlias, ServiceModelAlias}
  alias Tokengate.Repo

  # Averaging latencies returns a Decimal/Number depending on the DB; we
  # format it into a float-string for display.
  defp format_latency(%Decimal{} = d) do
    ms = d |> Decimal.round(0) |> Decimal.to_string()
    ms <> " ms"
  end

  defp format_latency(value) when is_number(value) do
    ms = value |> Float.round(0) |> :erlang.float_to_binary(decimals: 0)
    ms <> " ms"
  end

  defp format_latency(_), do: "—"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Mis servicios supervisados · Tokengate")
      |> attach_read_only_hook()
      |> load_services(user)

    {:ok, socket}
  end

  ## Defense-in-depth: this view is read-only by construction (no functional
  ## `handle_event/3` callbacks are defined). To guarantee that even a
  ## hostile client firing raw events at the WebSocket won't mutate state,
  ## we attach a `handle_event` hook that halts every event with a flash —
  ## the same pattern used by `ServicesLive`'s `require_admin_hook`. The
  ## hook MUST return `{:cont, socket}` or `{:halt, socket}` — it is NOT a
  ## `handle_event/3` callback, so it does not require `{:noreply, ...}`.
  defp attach_read_only_hook(socket) do
    attach_hook(socket, :read_only, :handle_event, fn _event, _params, socket ->
      {:halt, put_flash(socket, :error, "Esta vista es de solo lectura.")}
    end)
  end

  ## Data loading --------------------------------------------------------

  defp load_services(socket, %{id: user_id}) when is_binary(user_id) do
    services = Accounts.services_for_supervisor(user_id)
    service_ids = Enum.map(services, & &1.id)

    # granted_aliases: %{service_id => [model_alias_id, ...]} — scoped to the
    # supervisor's services only (never load the whole grant table into the
    # socket, even if the template only renders this supervisor's rows).
    granted_aliases =
      from(sma in ServiceModelAlias,
        where: sma.service_id in ^service_ids,
        select: {sma.service_id, sma.model_alias_id}
      )
      |> Repo.all()
      |> Enum.group_by(fn {service_id, _} -> service_id end, fn {_, alias_id} -> alias_id end)

    # Only the aliases actually granted to these services — not the full catalog.
    granted_alias_ids = granted_aliases |> Map.values() |> List.flatten() |> Enum.uniq()

    aliases =
      if granted_alias_ids == [] do
        []
      else
        from(ma in ModelAlias, where: ma.id in ^granted_alias_ids, order_by: [asc: ma.name])
        |> Repo.all()
      end

    timezone = socket.assigns[:timezone] || "Etc/UTC"
    thirty_days_ago = Periods.period_bounds("30d", timezone).from

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

  defp load_services(socket, _user), do: assign(socket, :services_empty?, true)

  ## Template helpers ----------------------------------------------------
  # Aliases for granted ids — reuses the helper signature from ServicesLive
  # so both views look identical from the outside.

  def granted_alias_ids(granted_aliases, service_id) do
    Map.get(granted_aliases, service_id, [])
  end

  def alias_names_for(granted_aliases, service_id, all_aliases) do
    granted_alias_ids(granted_aliases, service_id)
    |> Enum.map(&Enum.find(all_aliases, fn a -> a.id == &1 end))
    |> Enum.reject(&is_nil/1)
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

  ## Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Mis servicios supervisados
          <:subtitle>
            Servicios donde tienes permisos de supervisión (vista de solo lectura)
          </:subtitle>
          <:actions>
            <span
              id="supervised-readonly-badge"
              class="badge badge-info badge-lg gap-1.5"
              title="No puedes modificar estos servicios aquí. Contacta a un administrador para cambios."
            >
              <.icon name="hero-eye" class="w-4 h-4" /> Vista de solo lectura
            </span>
          </:actions>
        </.header>

        <div
          :if={@services_empty?}
          id="supervised-empty"
          class="card bg-base-100 border border-base-300 shadow-sm"
        >
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-wrench-screwdriver" class="w-12 h-12 text-base-content/30" />
            <h3 class="text-lg font-semibold mt-2">No supervisas ningún servicio.</h3>
            <p class="text-base-content/60 max-w-md">
              Un administrador puede asignarte servicios desde la sección de <strong>Servicios</strong>.
            </p>
          </div>
        </div>

        <div id="supervised-services" phx-update="stream">
          <div
            :for={{id, service} <- @streams.services}
            id={id}
            class="card bg-base-100 border border-base-300 shadow-sm mb-4"
          >
            <div class="card-body">
              <div class="flex items-start justify-between">
                <div>
                  <h3 class="font-semibold text-base-content flex items-center gap-2">
                    {service.name}
                    <span class="badge badge-ghost badge-sm" id={"service-readonly-#{service.id}"}>
                      <.icon name="hero-eye" class="w-3 h-3 mr-1" /> Solo lectura
                    </span>
                  </h3>
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
              </div>

              <% stats =
                Map.get(@service_stats, service.id, %{
                  total_cost: Decimal.new(0),
                  total_requests: 0,
                  total_input_tokens: 0,
                  total_output_tokens: 0,
                  avg_latency_ms: nil
                }) %>

              <div class="mt-3 grid grid-cols-2 md:grid-cols-4 gap-3">
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

              <div class="mt-4 grid grid-cols-1 md:grid-cols-3 gap-3">
                <div class="card bg-base-100 border border-base-300 shadow-sm">
                  <div class="card-body p-4">
                    <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                      Latencia media
                    </span>
                    <p class="mt-1.5 text-lg font-bold text-base-content">
                      {format_latency(stats.avg_latency_ms)}
                    </p>
                    <p class="text-xs text-base-content/40">30 días</p>
                  </div>
                </div>

                <div class="card bg-base-100 border border-base-300 shadow-sm md:col-span-2">
                  <div class="card-body p-4">
                    <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                      API Key
                    </span>
                    <%= if service.api_key do %>
                      <p class="mt-1.5 text-sm font-semibold text-base-content">
                        <span class="font-mono">{service.api_key.key_prefix}</span>…
                        <span class={[
                          "badge badge-xs ml-1",
                          if(service.api_key.status == "active",
                            do: "badge-success",
                            else: "badge-error"
                          )
                        ]}>
                          {service.api_key.status}
                        </span>
                      </p>
                      <p class="text-xs text-base-content/40 mt-1">Prefijo de la clave activa.</p>
                    <% else %>
                      <p class="mt-1.5 text-sm font-semibold text-base-content/40">Sin clave</p>
                    <% end %>
                  </div>
                </div>
              </div>

              <div class="mt-4">
                <p class="text-sm font-medium mb-2">Modelos permitidos</p>
                <div class="flex flex-wrap gap-2" id={"aliases-#{service.id}"}>
                  <%= if alias_names_for(@granted_aliases, service.id, @aliases) == [] do %>
                    <p class="text-xs text-base-content/40">
                      Este servicio no tiene modelos asignados.
                    </p>
                  <% else %>
                    <span
                      :for={alias <- alias_names_for(@granted_aliases, service.id, @aliases)}
                      id={"alias-badge-#{service.id}-#{alias.id}"}
                      class="badge badge-primary badge-sm"
                      title={alias.display_name}
                    >
                      {alias.name}
                    </span>
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
