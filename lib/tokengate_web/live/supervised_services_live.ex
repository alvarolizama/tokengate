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
      |> assign(:page_title, gettext("My supervised services") <> " · Tokengate")
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
        {:halt, put_flash(socket, :error, gettext("This view is read-only."))}
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
       |> put_flash(:error, gettext("You no longer supervise any service."))
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

    services = Accounts.services_for_supervisor(user.id)

    service_ids = Enum.map(services, & &1.id)

    # W2 lifecycle: a service may hold N keys, and `has_one :api_key` would
    # surface whichever row the preload happened to pick (often the revoked
    # one). The card must show the ACTIVE, non-hidden keys — one grouped query
    # for the whole set, never N+1.
    api_keys = Accounts.list_api_keys_for_services(service_ids)

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
    |> assign(:api_keys, api_keys)
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
      nil -> gettext("no requests")
      rate -> "#{Stats.format_percent(rate)} de error"
    end
  end

  # Cifras por debajo del centavo con precisión adaptativa (hasta 6
  # decimales, en Decimal): en el resumen de un servicio pequeño un "$0.00"
  # redondeado se lee como "no gastó nada".
  defp format_cost(%Decimal{} = d), do: Stats.money(d)

  defp format_cost(_), do: "$0.00"

  defp limit_label(%{unlimited_spend: true}), do: gettext("Unlimited credit")

  defp limit_label(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: gettext("Cap $%{amount}/month", amount: Decimal.to_string(limit))

  defp limit_label(_service), do: gettext("No budget") <> " " <> gettext("(top-ups only)")

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
          {gettext("My supervised services")}
          <:subtitle>
            {gettext("Services where you have supervision permissions (read-only view)")}
          </:subtitle>
          <:actions>
            <span
              id="supervised-readonly-badge"
              class="badge badge-info badge-lg gap-1.5"
              title={
                gettext(
                  "You cannot change these services here. Contact an administrator for changes."
                )
              }
            >
              <.icon name="hero-eye" class="w-4 h-4" /> {gettext("Read-only view")}
            </span>
          </:actions>
        </.header>

        <%!-- Listado: una fila por servicio supervisado (contrato .table común,
             read-only: sin headers ordenables ni acciones de mutación). --%>
        <div id="supervised-services">
          <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
            <.table
              id="supervised-rows"
              rows={@streams.services}
              row_item={fn {_id, service} -> service end}
              row_class="align-top"
              empty?={@services_empty?}
            >
              <:col :let={service} label={gettext("Service")}>
                <p class="font-medium text-sm">{service.name}</p>
                <div class="flex flex-wrap items-center gap-1.5 mt-1">
                  <span class="badge badge-ghost badge-xs" id={"service-readonly-#{service.id}"}>
                    <.icon name="hero-eye" class="w-3 h-3 mr-1" /> {gettext("Read-only")}
                  </span>
                  <span class="badge badge-outline badge-xs">
                    {service.concurrency_limit || 5} conc.
                  </span>
                  <span class="badge badge-outline badge-xs">{service.rpm_limit || 60} RPM</span>
                  <span class="badge badge-ghost badge-xs">{limit_label(service)}</span>
                </div>
              </:col>
              <:col :let={service} label={gettext("Keys")}>
                <% active_keys = Map.get(@api_keys, service.id, []) %>
                <%= if active_keys != [] do %>
                  <div class="flex items-center gap-1.5 flex-wrap">
                    <span class="badge badge-ghost badge-sm gap-1">
                      <.icon name="hero-key" class="w-3 h-3" />
                      <span class="font-mono">{hd(active_keys).key_prefix}</span>…
                      <span class={[
                        "badge badge-xs",
                        if(hd(active_keys).status == "active",
                          do: "badge-success",
                          else: "badge-error"
                        )
                      ]}>
                        {hd(active_keys).status}
                      </span>
                    </span>
                    <span :if={length(active_keys) > 1} class="badge badge-ghost badge-sm">
                      {gettext("%{count} keys", count: length(active_keys))}
                    </span>
                  </div>
                <% else %>
                  <span class="badge badge-ghost badge-sm">{gettext("No API key")}</span>
                <% end %>
              </:col>
              <:col :let={service} label={gettext("Models")}>
                <% models = model_names_for(@granted_models, service.id, @models) %>
                <div class="flex flex-wrap gap-1.5" id={"models-#{service.id}"}>
                  <%= if models == [] do %>
                    <p class="text-xs text-base-content/40">
                      {gettext("This service has no models assigned.")}
                    </p>
                  <% else %>
                    <span
                      :for={model <- models}
                      id={"model-badge-#{service.id}-#{model.id}"}
                      class="badge badge-primary badge-sm"
                    >
                      {model.name}
                    </span>
                  <% end %>
                </div>
              </:col>
              <:col :let={service} label={gettext("Actual spend")} align="right">
                <span class="font-mono text-sm" id={"metric-cost-#{service.id}"}>
                  {format_cost(summary_for(@summaries, service.id).cost_usd)}
                </span>
                <p class="text-[10px] text-base-content/40">{gettext("30 days")}</p>
              </:col>
              <:col :let={service} label={gettext("Requests 30d")} align="right">
                <% stats = summary_for(@summaries, service.id) %>
                <p class="font-mono text-sm" id={"metric-requests-#{service.id}"}>
                  {Stats.format_number(stats.request_count)}
                </p>
                <p
                  class="text-[10px] text-base-content/50 flex items-center gap-1 justify-end"
                  id={"metric-errors-#{service.id}"}
                  title={gettext("Errors")}
                >
                  <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                  {Stats.format_number(stats.error_count)}
                </p>
              </:col>
              <:col :let={service} label={gettext("Tokens")} align="right">
                <% stats = summary_for(@summaries, service.id) %>
                <p
                  class="text-xs font-mono flex items-center gap-1 justify-end"
                  id={"metric-input-#{service.id}"}
                  title={gettext("Tokens in")}
                >
                  <.icon name="hero-arrow-down-tray" class="w-3 h-3 text-base-content/40" />
                  {Stats.format_compact(stats.prompt_tokens)}
                </p>
                <p
                  class="text-xs font-mono flex items-center gap-1 justify-end"
                  id={"metric-output-#{service.id}"}
                  title={gettext("Tokens out")}
                >
                  <.icon name="hero-arrow-up-tray" class="w-3 h-3 text-base-content/40" />
                  {Stats.format_compact(stats.completion_tokens)}
                </p>
                <p class="text-[10px] text-base-content/40">
                  {gettext("cache hit")} {Stats.cache_hit_pct(
                    stats.prompt_tokens,
                    stats.cache_read_tokens
                  )} · {Stats.format_tps(stats.avg_tps)} tps
                </p>
              </:col>
              <:col :let={service} label={gettext("Average latency")} align="right">
                <span class="font-mono text-xs" id={"metric-latency-#{service.id}"}>
                  {Stats.format_ms(summary_for(@summaries, service.id).avg_latency_ms)}
                </span>
                <p class="text-[10px] text-base-content/40">{gettext("30 days")}</p>
              </:col>
              <:action :let={service}>
                <.link
                  navigate={~p"/services/supervised/#{service.id}"}
                  id={"service-stats-link-#{service.id}"}
                  class="btn btn-xs btn-primary"
                  title={gettext("View full stats")}
                >
                  <.icon name="hero-chart-bar" class="w-3.5 h-3.5" /> {gettext("View full stats")}
                </.link>
              </:action>
              <:empty>
                <div id="supervised-empty" class="flex flex-col items-center">
                  <.icon name="hero-wrench-screwdriver" class="size-12 text-base-content/30" />
                  <h3 class="text-lg font-semibold mt-2">{gettext("You supervise no services.")}</h3>
                  <p class="text-base-content/60 max-w-md">
                    {gettext("An administrator can assign you services from the")}
                    <strong>{gettext("Services")}</strong> {gettext("section.")}
                  </p>
                </div>
              </:empty>
            </.table>
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
                {gettext("Summary of your services")}
              </h2>
              <span class="text-[10px] text-base-content/40 hidden sm:inline">
                {gettext("last 30 days")}
              </span>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
              <.metric_tile
                id="totals-services"
                label={gettext("Services")}
                value={Integer.to_string(@service_count)}
                icon="hero-wrench-screwdriver"
                accent="primary"
              />
              <.metric_tile
                id="totals-cost"
                label={gettext("Actual spend")}
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
                label={gettext("Errors")}
                value={Stats.format_number(@totals.error_count)}
                icon="hero-exclamation-triangle"
                accent={if @totals.error_count > 0, do: "error", else: "neutral"}
                sub={error_rate_label(@totals.request_count, @totals.error_count)}
              />
            </div>
          </div>
        </section>
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
