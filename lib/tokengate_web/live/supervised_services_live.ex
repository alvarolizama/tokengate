defmodule TokengateWeb.SupervisedServicesLive do
  @moduledoc """
  Read-only summary of the services the current user supervises.

  Two things live here that are *not* an admin concern:

    * **Access** — the only thing that grants this page is a live row in
      `service_supervisors` for the signed-in user (enforced by the
      `:require_service_supervisor` `on_mount` hook on the router's
      `:service_viewer` session). Removing the user as supervisor revokes the
      access on the next mount, and a view already open reacts in the same
      instant through the `{:supervisor_removed, service_id}` PubSub notice.
    * **A summary per service** — spend, volume, tokens, errors and latency for
      the last 30 days, plus its API-key status and granted models. The full
      breakdown (period selector, per-model table, daily chart, recent requests)
      lives in `SupervisedServiceStatsLive` at `/services/supervised/:id`.

  Mutations stay out of reach: an admin action (create / edit / delete /
  regenerate key / revoke key / toggle model) lives exclusively in
  `TokengateWeb.ServicesLive` behind the `:admin` live_session.

  Intentionally NOT defined: any `handle_event/3` callback. The view is pure
  display — even a hostile client firing a `phx-click` straight at the
  WebSocket finds no handler, and the `:read_only` hook halts every event
  before it reaches one.
  """

  use TokengateWeb, :live_view

  import TokengateWeb.KpiHelpers, only: [metric_tile: 1]

  alias Tokengate.Accounts
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  alias Tokengate.Providers
  alias Tokengate.Repo
  alias TokengateWeb.StatsHelpers, as: Stats

  # Same window the card labels advertise ("30 días").
  @summary_period "30d"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Accounts.supervised_services_topic(user.id))
    end

    socket =
      socket
      |> assign(:page_title, "Mis servicios supervisados · Tokengate")
      |> attach_read_only_hook()
      |> load_services()

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
    attach_hook(socket, :read_only, :handle_event, fn event, _params, socket ->
      # `set-timezone` is the app-wide sidebar selector: it writes the user's
      # own timezone, never service data, so it stays allowed here.
      if event in ["set-timezone"] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "Esta vista es de solo lectura.")}
      end
    end)
  end

  ## Supervision changes ---------------------------------------------------

  ## A service was assigned to this supervisor while the page was open: reload
  ## the summary so the new card appears without a manual refresh.
  @impl true
  def handle_info({:supervisor_added, _service_id}, socket) do
    {:noreply, load_services(socket)}
  end

  ## Revocation in the same instant: the removed card disappears, and when the
  ## user has no supervised service left the whole page is out of reach, so it
  ## redirects to the dashboard.
  def handle_info({:supervisor_removed, _service_id}, socket) do
    socket = load_services(socket)

    if socket.assigns.services_empty? do
      {:noreply,
       socket
       |> put_flash(:error, "Ya no supervisas ningún servicio.")
       |> push_navigate(to: ~p"/dashboard")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Data loading --------------------------------------------------------

  defp load_services(socket) do
    user = socket.assigns.current_user
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    services =
      user.id
      |> Accounts.services_for_supervisor()
      |> Repo.preload(:api_key)

    service_ids = Enum.map(services, & &1.id)

    # granted_models: %{service_id => [model_id, ...]} — scoped to the
    # supervisor's services only (never load the whole grant table into the
    # socket, even if the template only renders this supervisor's rows), and
    # only the catalog rows actually granted (not the full catalog).
    granted_models = Providers.granted_models_by_service(service_ids)

    models =
      granted_models
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Providers.models_by_ids()

    bounds = Periods.period_bounds(@summary_period, timezone)

    # One aggregate per service for the whole set, shared between every
    # supervisor looking at their page for ~5s (DashboardCache TTL): without
    # it, N supervisors with M services each would run N×M group-by queries.
    summaries =
      DashboardCache.fetch_or_compute(
        {:supervised_services_summary, user.id, @summary_period, timezone},
        fn -> Rollup.service_summaries(service_ids, from: bounds.from, to: bounds.to) end
      )

    socket
    |> stream(:services, services,
      reset: true,
      dom_id: &"supervised-service-#{&1.id}"
    )
    |> assign(:services_empty?, services == [])
    |> assign(:service_count, length(services))
    |> assign(:granted_models, granted_models)
    |> assign(:models, models)
    |> assign(:summaries, summaries)
    |> assign(:totals, totals(summaries))
  end

  defp totals(summaries) do
    summaries
    |> Map.values()
    |> Enum.reduce(
      %{
        cost_usd: Decimal.new(0),
        request_count: 0,
        error_count: 0,
        prompt_tokens: 0,
        completion_tokens: 0
      },
      fn row, acc ->
        %{
          cost_usd: Decimal.add(acc.cost_usd, row.cost_usd),
          request_count: acc.request_count + row.request_count,
          error_count: acc.error_count + row.error_count,
          prompt_tokens: acc.prompt_tokens + row.prompt_tokens,
          completion_tokens: acc.completion_tokens + row.completion_tokens
        }
      end
    )
  end

  defp summary_for(summaries, service_id) do
    Map.get(summaries, service_id, %{
      cost_usd: Decimal.new(0),
      request_count: 0,
      error_count: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      avg_latency_ms: nil,
      avg_tps: nil
    })
  end

  ## Template helpers ----------------------------------------------------

  defp error_rate(0, _errors), do: nil
  defp error_rate(requests, errors), do: Float.round(errors / requests, 4)

  defp error_rate_label(requests, errors) do
    case error_rate(requests, errors) do
      nil -> "sin requests"
      rate -> "#{Stats.format_percent(rate)} de error"
    end
  end

  # Cifras por debajo del centavo se muestran con 4 decimales: en el resumen
  # de un servicio pequeño un "$0.00" redondeado se lee como "no gastó nada".
  defp format_cost(%Decimal{} = d) do
    rounded_away? =
      Decimal.compare(d, Decimal.new(0)) == :gt and Decimal.compare(d, Decimal.new("0.01")) == :lt

    if rounded_away? do
      "$" <> (d |> Decimal.round(4) |> Decimal.to_string())
    else
      "$" <> Stats.format_decimal(d)
    end
  end

  defp format_cost(_), do: "$0.00"

  defp subscription_label(%{unlimited_spend: true}), do: "Crédito ilimitado"

  defp subscription_label(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: "Límite $#{Decimal.to_string(limit)}/mes"

  defp subscription_label(_service), do: "Sin límite (solo top-ups)"

  ## Render --------------------------------------------------------------

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

        <%!-- Totales del conjunto supervisado: la foto de arriba antes de
             entrar servicio por servicio. --%>
        <section
          :if={not @services_empty?}
          id="supervised-totals"
          class="card bg-base-100 border border-base-300 shadow-sm"
        >
          <div class="card-body gap-4">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-base">
                <.icon name="hero-chart-pie" class="w-5 h-5 text-base-content/60" />
                Resumen de tus servicios
              </h2>
              <span class="text-[10px] text-base-content/40 hidden sm:inline">
                últimos 30 días
              </span>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
              <.metric_tile
                id="totals-services"
                label="Servicios"
                value={Integer.to_string(@service_count)}
                icon="hero-wrench-screwdriver"
                accent="primary"
              />
              <.metric_tile
                id="totals-cost"
                label="Gasto real"
                value={format_cost(@totals.cost_usd)}
                icon="hero-currency-dollar"
                accent="success"
              />
              <.metric_tile
                id="totals-requests"
                label="Requests"
                value={Stats.format_number(@totals.request_count)}
                icon="hero-bolt"
                accent="accent"
                sub={
                  "#{Stats.format_compact(@totals.prompt_tokens)} in / #{Stats.format_compact(@totals.completion_tokens)} out"
                }
              />
              <.metric_tile
                id="totals-errors"
                label="Errores"
                value={Stats.format_number(@totals.error_count)}
                icon="hero-exclamation-triangle"
                accent={if @totals.error_count > 0, do: "error", else: "neutral"}
                sub={error_rate_label(@totals.request_count, @totals.error_count)}
              />
            </div>
          </div>
        </section>

        <div id="supervised-services" phx-update="stream" class="space-y-4">
          <article
            :for={{id, service} <- @streams.services}
            id={id}
            class="card bg-base-100 border border-base-300 shadow-sm"
          >
            <div class="card-body gap-4">
              <% stats = summary_for(@summaries, service.id) %>

              <header class="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h3 class="font-semibold text-base-content flex items-center gap-2">
                    {service.name}
                    <span class="badge badge-ghost badge-sm" id={"service-readonly-#{service.id}"}>
                      <.icon name="hero-eye" class="w-3 h-3 mr-1" /> Solo lectura
                    </span>
                  </h3>

                  <div class="flex flex-wrap items-center gap-2 mt-2">
                    <span class="badge badge-outline badge-sm">
                      {service.concurrency_limit || 5} conc.
                    </span>
                    <span class="badge badge-outline badge-sm">
                      {service.rpm_limit || 60} RPM
                    </span>
                    <span class="badge badge-ghost badge-sm">{subscription_label(service)}</span>

                    <%= if service.api_key do %>
                      <span class="badge badge-ghost badge-sm gap-1">
                        <.icon name="hero-key" class="w-3 h-3" />
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
                      </span>
                    <% else %>
                      <span class="badge badge-ghost badge-sm">Sin API key</span>
                    <% end %>
                  </div>
                </div>

                <.link
                  navigate={~p"/services/supervised/#{service.id}"}
                  id={"service-stats-link-#{service.id}"}
                  class="btn btn-sm btn-primary"
                >
                  <.icon name="hero-chart-bar" class="w-4 h-4" /> Ver stats completos
                </.link>
              </header>

              <div class="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-3">
                <.metric_tile
                  id={"metric-cost-#{service.id}"}
                  label="Gasto real"
                  value={format_cost(stats.cost_usd)}
                  icon="hero-currency-dollar"
                  accent="success"
                  sub="30 días"
                />
                <.metric_tile
                  id={"metric-requests-#{service.id}"}
                  label="Requests"
                  value={Stats.format_number(stats.request_count)}
                  icon="hero-bolt"
                  accent="primary"
                  sub="30 días"
                />
                <.metric_tile
                  id={"metric-input-#{service.id}"}
                  label="Tokens in"
                  value={Stats.format_compact(stats.prompt_tokens)}
                  icon="hero-arrow-down-tray"
                  accent="accent"
                  sub={"cache hit #{Stats.cache_hit_pct(stats.prompt_tokens, stats.cache_read_tokens)}"}
                />
                <.metric_tile
                  id={"metric-output-#{service.id}"}
                  label="Tokens out"
                  value={Stats.format_compact(stats.completion_tokens)}
                  icon="hero-arrow-up-tray"
                  accent="warning"
                  sub={"#{Stats.format_tps(stats.avg_tps)} tps"}
                />
                <.metric_tile
                  id={"metric-errors-#{service.id}"}
                  label="Errores"
                  value={Stats.format_number(stats.error_count)}
                  icon="hero-exclamation-triangle"
                  accent={if stats.error_count > 0, do: "error", else: "neutral"}
                  sub={error_rate_label(stats.request_count, stats.error_count)}
                />
                <.metric_tile
                  id={"metric-latency-#{service.id}"}
                  label="Latencia media"
                  value={Stats.format_ms(stats.avg_latency_ms)}
                  icon="hero-clock"
                  accent="neutral"
                  sub="30 días"
                />
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Modelos permitidos
                </span>
                <div class="flex flex-wrap gap-2" id={"models-#{service.id}"}>
                  <%= if model_names_for(@granted_models, service.id, @models) == [] do %>
                    <p class="text-xs text-base-content/40">
                      Este servicio no tiene models asignados.
                    </p>
                  <% else %>
                    <span
                      :for={model <- model_names_for(@granted_models, service.id, @models)}
                      id={"model-badge-#{service.id}-#{model.id}"}
                      class="badge badge-primary badge-sm"
                    >
                      {model.name}
                    </span>
                  <% end %>
                </div>
              </div>
            </div>
          </article>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  # Aliases for granted ids — reuses the helper signature from ServicesLive
  # so both views look identical from the outside.
  def granted_alias_ids(granted_models, service_id) do
    Map.get(granted_models, service_id, [])
  end

  def model_names_for(granted_models, service_id, all_models) do
    granted_alias_ids(granted_models, service_id)
    |> Enum.map(&Enum.find(all_models, fn a -> a.id == &1 end))
    |> Enum.reject(&is_nil/1)
  end
end
