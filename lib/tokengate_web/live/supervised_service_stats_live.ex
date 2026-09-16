defmodule TokengateWeb.SupervisedServiceStatsLive do
  @moduledoc """
  Full read-only stats for **one** supervised service.

  This is the drill-down of `/services/supervised`: the summary card answers
  "how is this service doing?" in one line, and this page answers "what exactly
  happened?" — period selector, KPI strip, daily usage per model, per-model
  breakdown, status classes, recent requests and the read-only configuration
  (API key prefix, limits, granted models, who else supervises it).

  ## Access

  Nothing but a live `service_supervisors` row for **this** service opens this
  page: neither a global role nor supervising a *different* service is enough.
  The check runs on every mount (socket reconnects included), and an open view
  navigates away the instant the row is removed — `Accounts.remove_service_supervisor/2`
  broadcasts `{:supervisor_removed, service_id}` on
  `Accounts.supervised_services_topic/1`.

  ## Read-only contract

  Same as the list view: no mutation callback exists, and the `:read_only` hook
  halts every event except the read-only allowlist (`load_more` pagination and
  the app-wide `set-timezone` selector). The period is switched through
  `patch` navigation, which does not go through events at all.
  """

  use TokengateWeb, :live_view

  import TokengateWeb.KpiHelpers, only: [metric_tile: 1]

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  alias Tokengate.Providers
  alias Tokengate.Repo
  alias TokengateWeb.StatsHelpers, as: Stats

  @periods [{"today", "Hoy"}, {"7d", "7 días"}, {"30d", "30 días"}, {"90d", "90 días"}]
  @default_period "30d"
  @page_size 25
  # Events that do not touch service state and stay allowed on a read-only page.
  @allowed_events ["load_more", "set-timezone"]

  @impl true
  def mount(%{"service_id" => service_id}, _session, socket) do
    user = socket.assigns.current_user

    case Accounts.get_service(service_id) do
      nil ->
        {:ok, deny(socket, "Ese servicio no existe.")}

      service ->
        if Accounts.supervises_service?(user.id, service.id) do
          if connected?(socket) do
            Phoenix.PubSub.subscribe(
              Tokengate.PubSub,
              Accounts.supervised_services_topic(user.id)
            )
          end

          granted_models = Providers.granted_models_by_service([service.id])

          {:ok,
           socket
           |> assign(:denied?, false)
           |> assign(:page_title, "Stats · #{service.name} · Tokengate")
           |> assign(:service, Repo.preload(service, [:subscription, :api_key]))
           |> assign(:granted_models, granted_models)
           |> assign(
             :models,
             granted_models |> Map.values() |> List.flatten() |> Providers.models_by_ids()
           )
           |> assign(:supervisors, Accounts.service_supervisors(service.id))
           |> assign(:periods, @periods)
           |> assign(:period, @default_period)
           |> assign(:summary, empty_summary())
           |> assign(:model_rows, [])
           |> assign(:series, %{days: [], series: %{}})
           |> assign(:series_labels, [])
           |> assign(:cursor, nil)
           |> assign(:has_more, false)
           |> attach_read_only_hook()}
        else
          {:ok, deny(socket, "No supervisas ese servicio.")}
        end
    end
  end

  ## No supervisor row for this service → no detail. The page renders a denied
  ## placeholder (so the dead render is always valid) and sends the client back
  ## to the supervised list, where the hook decides whether the user still has
  ## anything to see at all.
  defp deny(socket, message) do
    socket
    |> assign(:denied?, true)
    |> assign(:page_title, "Sin acceso · Tokengate")
    |> put_flash(:error, message)
    |> push_navigate(to: ~p"/services/supervised")
  end

  defp attach_read_only_hook(socket) do
    attach_hook(socket, :read_only, :handle_event, fn event, _params, socket ->
      if event in @allowed_events do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "Esta vista es de solo lectura.")}
      end
    end)
  end

  ## Params / period ------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.denied? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:period, parse_period(params["period"]))
       |> load_bundle()}
    end
  end

  defp parse_period(period) do
    if period in Enum.map(@periods, &elem(&1, 0)), do: period, else: @default_period
  end

  ## Revocation -----------------------------------------------------------

  ## Removing the user as supervisor of this service closes the page: the
  ## detail exists only while the row does.
  @impl true
  def handle_info({:supervisor_removed, service_id}, socket) do
    if socket.assigns.service.id == service_id do
      {:noreply,
       socket
       |> put_flash(:error, "Ya no supervisas este servicio.")
       |> push_navigate(to: ~p"/services/supervised")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply, load_logs(socket, :more)}
    else
      {:noreply, socket}
    end
  end

  ## Data loading ---------------------------------------------------------

  defp load_bundle(socket) do
    service = socket.assigns.service
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    period = socket.assigns.period
    bounds = Periods.period_bounds(period, timezone)

    # The summary bundle (cost/tokens/status/top models + the 5-min window) is
    # the expensive part; the DashboardCache shares it across every viewer of
    # this service+period for ~5s.
    summary =
      DashboardCache.fetch_or_compute(
        {:supervised_service_stats, service.id, period, timezone},
        fn -> Logs.service_stats(service.id, from: bounds.from, to: bounds.to) end
      )

    model_rows =
      Rollup.breakdown_by_model(nil,
        service_id: service.id,
        from: bounds.from,
        to: bounds.to
      )

    daily =
      Rollup.daily_series_by_model_for_service(service.id,
        from: bounds.from,
        to: bounds.to,
        timezone: timezone
      )

    socket
    |> assign(:summary, summary)
    |> assign(:model_rows, model_rows)
    |> assign(:series, Stats.pivot_daily_series(daily))
    |> assign(:series_labels, daily |> Enum.map(& &1.label) |> Enum.uniq() |> Enum.sort())
    |> load_logs(:reset)
  end

  # Recent activity is a "what is happening right now" feed, deliberately not
  # scoped to the selected period window (the period drives the aggregates
  # above). Cursor pagination on `inserted_at`, newest first.
  defp load_logs(socket, mode) do
    base = %{"service_id" => socket.assigns.service.id, "limit" => @page_size}

    filters =
      case {mode, socket.assigns.cursor} do
        {:more, %DateTime{} = cursor} -> Map.put(base, "before", cursor)
        _ -> base
      end

    logs = Logs.list_logs(filters)

    socket =
      socket
      |> assign(:has_more, length(logs) == @page_size)
      |> then(fn s ->
        if mode == :reset, do: stream(s, :logs, logs, reset: true), else: stream(s, :logs, logs)
      end)

    case List.last(logs) do
      nil -> socket
      oldest -> assign(socket, :cursor, oldest.inserted_at)
    end
  end

  defp empty_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      request_count: 0,
      avg_latency_ms: nil,
      avg_ttft_ms: nil,
      avg_tps: nil,
      status_breakdown: %{"2xx" => 0, "4xx" => 0, "5xx" => 0},
      top_models: [],
      last_request_at: nil,
      realtime_5min: %{request_count: 0, error_count: 0, avg_latency_ms: nil, error_rate: 0.0}
    }
  end

  ## Template helpers -----------------------------------------------------

  # Cifras por debajo del centavo con 4 decimales: un "$0.00" redondeado se lee
  # como "no gastó nada" en servicios pequeños.
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

  defp error_rate(0, _errors), do: nil
  defp error_rate(requests, errors), do: Float.round(errors / requests, 4)

  defp error_rate_label(requests, errors) do
    case error_rate(requests, errors) do
      nil -> "sin requests"
      rate -> "#{Stats.format_percent(rate)} de error"
    end
  end

  defp status_total(%{"2xx" => a, "4xx" => b, "5xx" => c}), do: a + b + c

  defp status_share(_count, 0), do: "0%"
  defp status_share(count, total), do: Stats.format_percent(count / total)

  defp sub_label(%{subscription: %{name: name}}) when is_binary(name), do: name
  defp sub_label(_service), do: "Crédito ilimitado"

  defp supervisor_label(%{user: %{name: name, email: email}}) when is_binary(name),
    do: "#{name} · #{email}"

  defp supervisor_label(%{user: %{email: email}}), do: email
  defp supervisor_label(_), do: "—"

  defp status_badge(code) when is_integer(code) and code >= 200 and code < 300,
    do: "badge-success"

  defp status_badge(code) when is_integer(code) and code >= 400 and code < 500,
    do: "badge-warning"

  defp status_badge(code) when is_integer(code) and code >= 500 and code < 600, do: "badge-error"
  defp status_badge(_), do: "badge-ghost"

  defp model_display(req, resp) do
    cond do
      is_binary(resp) and resp != "" and resp != req -> "#{req} → #{resp}"
      true -> req || "—"
    end
  end

  ## Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div
        :if={@denied?}
        id="supervised-service-denied"
        class="card bg-base-100 border border-base-300"
      >
        <div class="card-body items-center text-center py-12">
          <.icon name="hero-lock-closed" class="w-12 h-12 text-base-content/30" />
          <h3 class="text-lg font-semibold mt-2">Sin acceso a este servicio.</h3>
        </div>
      </div>

      <div :if={not @denied?} class="space-y-6">
        <header class="flex flex-wrap items-start justify-between gap-4 pb-4">
          <div>
            <div class="flex items-center gap-2 text-xs text-base-content/60">
              <.link navigate={~p"/services/supervised"} class="hover:underline">
                Servicios supervisados
              </.link>
              <span>›</span>
              <span>Stats completos</span>
            </div>
            <h1 class="text-lg font-semibold leading-8 mt-1 flex items-center gap-2">
              {@service.name}
              <span class="badge badge-ghost badge-sm" id="supervised-service-readonly">
                <.icon name="hero-eye" class="w-3 h-3 mr-1" /> Solo lectura
              </span>
            </h1>
            <p class="text-sm text-base-content/70">
              Sub: {sub_label(@service)} · últimos {period_label(@period)}
            </p>
          </div>

          <div class="flex items-center gap-1" id="period-selector">
            <.link
              :for={{value, label} <- @periods}
              patch={~p"/services/supervised/#{@service.id}?period=#{value}"}
              id={"period-#{value}"}
              class={[
                "btn btn-xs",
                if(@period == value, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              {label}
            </.link>
          </div>
        </header>

        <%!-- KPI strip for the selected period --%>
        <div class="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-3">
          <.metric_tile
            id="kpi-cost"
            label="Gasto real"
            value={format_cost(@summary.total_cost_usd)}
            icon="hero-currency-dollar"
            accent="success"
            sub={period_label(@period)}
          />
          <.metric_tile
            id="kpi-requests"
            label="Requests"
            value={Stats.format_number(@summary.request_count)}
            icon="hero-bolt"
            accent="primary"
            sub={"#{@summary.realtime_5min.request_count} en 5 min"}
          />
          <.metric_tile
            id="kpi-input"
            label="Tokens in"
            value={Stats.format_compact(@summary.total_prompt_tokens)}
            icon="hero-arrow-down-tray"
            accent="accent"
            sub={"cache hit #{Stats.cache_hit_pct(@summary.total_prompt_tokens, @summary.total_cache_read_tokens)}"}
          />
          <.metric_tile
            id="kpi-output"
            label="Tokens out"
            value={Stats.format_compact(@summary.total_completion_tokens)}
            icon="hero-arrow-up-tray"
            accent="warning"
            sub={"#{Stats.format_tps(@summary.avg_tps)} tps"}
          />
          <.metric_tile
            id="kpi-errors"
            label="Errores"
            value={
              Stats.format_number(@summary.status_breakdown["4xx"] + @summary.status_breakdown["5xx"])
            }
            icon="hero-exclamation-triangle"
            accent={
              if(@summary.status_breakdown["4xx"] + @summary.status_breakdown["5xx"] > 0,
                do: "error",
                else: "neutral"
              )
            }
            sub={
              error_rate_label(
                @summary.request_count,
                @summary.status_breakdown["5xx"] + @summary.status_breakdown["4xx"]
              )
            }
          />
          <.metric_tile
            id="kpi-latency"
            label="Latencia media"
            value={Stats.format_ms(@summary.avg_latency_ms)}
            icon="hero-clock"
            accent="neutral"
            sub={
              "último request: " <>
                Stats.format_dt(@summary.last_request_at, @timezone)
            }
          />
        </div>

        <%!-- Daily usage per model --%>
        <div :if={@series.days != []} class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-base">
                <.icon name="hero-chart-bar" class="w-5 h-5 text-base-content/60" />
                Uso diario por modelo
              </h2>
              <span class="text-[10px] text-base-content/40 hidden sm:inline">
                {period_label(@period)}
              </span>
            </div>

            <% max = Stats.daily_series_max(@series) %>
            <div class="flex gap-4 mt-2">
              <div class="flex-1">
                <div class="flex items-end gap-px h-32">
                  <div
                    :for={day <- @series.days}
                    class="flex-1 flex flex-col items-center justify-end h-full group relative"
                  >
                    <div class="hidden group-hover:block absolute -top-1 -translate-y-full left-1/2 -translate-x-1/2 z-20 pointer-events-none">
                      <div class="bg-base-300 text-base-content text-[10px] rounded-md px-2 py-1 shadow-lg whitespace-nowrap">
                        <div class="font-semibold">{Calendar.strftime(day, "%d %b")}</div>
                        <div :for={label <- @series_labels} class="flex justify-between gap-2">
                          <span class="truncate max-w-[100px]">{label}</span>
                          <span class="tabular-nums">
                            {Stats.format_number(Map.get(@series.series[label] || %{}, day, 0))}
                          </span>
                        </div>
                      </div>
                    </div>

                    <div class="w-full flex flex-col-reverse rounded-t overflow-hidden">
                      <div
                        :for={label <- @series_labels}
                        class={[
                          "w-full",
                          Stats.sparkline_color(Enum.find_index(@series_labels, &(&1 == label)) || 0)
                        ]}
                        style={"height: #{Stats.sparkline_bar_height(Map.get(@series.series[label] || %{}, day, 0), max)}%"}
                      />
                    </div>
                  </div>
                </div>

                <div class="flex gap-px mt-1">
                  <span
                    :for={day <- @series.days}
                    class="flex-1 text-center text-[9px] text-base-content/40"
                  >
                    {Calendar.strftime(day, "%d")}
                  </span>
                </div>
              </div>

              <div class="w-40 shrink-0 border-l border-base-300 pl-3">
                <div class="text-[10px] font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                  Modelos
                </div>
                <div class="space-y-1.5">
                  <div
                    :for={{label, idx} <- Enum.with_index(@series_labels)}
                    class="flex items-center gap-1.5"
                  >
                    <span class={["w-2 h-2 rounded-sm shrink-0", Stats.sparkline_color(idx)]} />
                    <span class="text-[10px] truncate flex-1">{label}</span>
                    <span class="text-[9px] text-base-content/50 shrink-0">
                      {Stats.format_number(Stats.sparkline_label_total(@series.series[label] || %{}))}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-3">
          <%!-- Status classes --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm" id="status-breakdown">
            <div class="card-body p-4 gap-2">
              <h3 class="card-title text-sm">
                <strong>Estados</strong> · {period_label(@period)}
              </h3>
              <%= for {class, badge} <- [{"2xx", "badge-success"}, {"4xx", "badge-warning"}, {"5xx", "badge-error"}] do %>
                <div class="flex items-center justify-between text-sm">
                  <span class={"badge badge-sm #{badge}"}>{class}</span>
                  <span class="flex items-center gap-3">
                    <span class="font-mono">
                      {Stats.format_number(@summary.status_breakdown[class])}
                    </span>
                    <span class="text-xs text-base-content/40 tabular-nums w-12 text-right">
                      {status_share(
                        @summary.status_breakdown[class],
                        status_total(@summary.status_breakdown)
                      )}
                    </span>
                  </span>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Top models --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm" id="top-models">
            <div class="card-body p-4 gap-2">
              <h3 class="card-title text-sm">Top modelos · {period_label(@period)}</h3>
              <%= if @summary.top_models == [] do %>
                <p class="text-xs text-base-content/40">Sin requests en el período.</p>
              <% else %>
                <ol class="space-y-1">
                  <li
                    :for={row <- @summary.top_models}
                    class="flex items-center justify-between text-sm"
                  >
                    <span class="font-mono truncate">{row.model_requested || "—"}</span>
                    <span class="badge badge-sm badge-ghost">
                      {Stats.format_number(row.count)}
                    </span>
                  </li>
                </ol>
              <% end %>
            </div>
          </div>

          <%!-- Who else supervises it --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm" id="service-supervisors">
            <div class="card-body p-4 gap-2">
              <h3 class="card-title text-sm">Supervisores del servicio</h3>
              <ul class="space-y-1">
                <li
                  :for={supervisor <- @supervisors}
                  id={"service-supervisor-#{supervisor.user_id}"}
                  class="flex items-center gap-2 text-sm"
                >
                  <.icon name="hero-user" class="w-4 h-4 text-base-content/40" />
                  <span class="truncate">{supervisor_label(supervisor)}</span>
                </li>
              </ul>
              <p class="text-xs text-base-content/40">
                La asignación la gestiona un administrador desde Servicios.
              </p>
            </div>
          </div>
        </div>

        <%!-- Per-model breakdown --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
              Modelos usados · {period_label(@period)}
            </h2>
            <%= if @model_rows == [] do %>
              <p class="text-sm text-base-content/40 py-6 text-center" id="model-rows-empty">
                Sin datos para este periodo.
              </p>
            <% else %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="model-rows">
                  <thead>
                    <tr>
                      <th>Modelo</th>
                      <th class="text-right">Requests</th>
                      <th class="text-right">Costo</th>
                      <th class="text-right">Tokens in</th>
                      <th class="text-right">Tokens out</th>
                      <th class="text-right">Cache %</th>
                      <th class="text-right">TPS</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- @model_rows} id={"model-row-#{row.model_id || "unknown"}"}>
                      <td class="font-medium">{row.model_name}</td>
                      <td class="text-right font-mono">{Stats.format_number(row.request_count)}</td>
                      <td class="text-right font-mono">${Stats.format_decimal(row.cost_usd)}</td>
                      <td class="text-right font-mono">{Stats.format_number(row.prompt_tokens)}</td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.completion_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)}
                      </td>
                      <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Read-only configuration --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="service-config">
          <div class="card-body p-4 gap-3">
            <h2 class="card-title text-base">
              <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-base-content/60" />
              Configuración (solo lectura)
            </h2>

            <dl class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 text-sm">
              <div class="rounded-xl border border-base-300 px-3 py-2">
                <dt class="text-[10px] uppercase tracking-wide text-base-content/60">API key</dt>
                <dd class="mt-1 flex items-center gap-2">
                  <%= if @service.api_key do %>
                    <span class="font-mono">{@service.api_key.key_prefix}…</span>
                    <span class={[
                      "badge badge-xs",
                      if(@service.api_key.status == "active",
                        do: "badge-success",
                        else: "badge-error"
                      )
                    ]}>
                      {@service.api_key.status}
                    </span>
                  <% else %>
                    <span class="text-base-content/40">Sin clave</span>
                  <% end %>
                </dd>
              </div>

              <div class="rounded-xl border border-base-300 px-3 py-2">
                <dt class="text-[10px] uppercase tracking-wide text-base-content/60">Concurrencia</dt>
                <dd class="mt-1 font-mono">{@service.concurrency_limit || 5}</dd>
              </div>

              <div class="rounded-xl border border-base-300 px-3 py-2">
                <dt class="text-[10px] uppercase tracking-wide text-base-content/60">RPM</dt>
                <dd class="mt-1 font-mono">{@service.rpm_limit || 60}</dd>
              </div>

              <div class="rounded-xl border border-base-300 px-3 py-2">
                <dt class="text-[10px] uppercase tracking-wide text-base-content/60">Crédito</dt>
                <dd class="mt-1">{sub_label(@service)}</dd>
              </div>
            </dl>

            <div class="flex flex-wrap items-center gap-2">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                Modelos permitidos
              </span>
              <div class="flex flex-wrap gap-2" id={"models-#{@service.id}"}>
                <%= if model_names_for(@granted_models, @service.id, @models) == [] do %>
                  <span class="text-xs text-base-content/40">
                    Este servicio no tiene models asignados.
                  </span>
                <% else %>
                  <span
                    :for={model <- model_names_for(@granted_models, @service.id, @models)}
                    id={"model-badge-#{@service.id}-#{model.id}"}
                    class="badge badge-primary badge-sm"
                  >
                    {model.name}
                  </span>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Recent requests --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-bars-3-bottom-left" class="w-5 h-5 text-base-content/60" />
              Actividad reciente
            </h2>
            <p class="text-xs text-base-content/60">
              Últimos requests del servicio, sin filtrar por período.
            </p>

            <div class="overflow-x-auto mt-3">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Fecha</th>
                    <th>Modelo</th>
                    <th>Estado</th>
                    <th class="text-right">Input</th>
                    <th class="text-right">Output</th>
                    <th class="text-right">Costo</th>
                    <th class="text-right">Latencia</th>
                  </tr>
                </thead>
                <tbody id="supervised-service-logs" phx-update="stream">
                  <tr id="supervised-service-logs-empty" class="hidden only:table-row">
                    <td colspan="7" class="text-center py-8 text-base-content/40">
                      Este servicio todavía no tiene requests.
                    </td>
                  </tr>
                  <tr :for={{id, log} <- @streams.logs} id={id}>
                    <td class="whitespace-nowrap text-sm">
                      {Stats.format_dt(log.inserted_at, @timezone)}
                    </td>
                    <td class="text-sm">
                      {model_display(log.model_requested, log.model_responded)}
                    </td>
                    <td>
                      <span class={"badge badge-sm #{status_badge(log.status_code)}"}>
                        {log.status_code}
                      </span>
                    </td>
                    <td class="text-right text-sm">{Stats.format_number(log.prompt_tokens || 0)}</td>
                    <td class="text-right text-sm">
                      {Stats.format_number(log.completion_tokens || 0)}
                    </td>
                    <td class="text-right text-sm font-mono">
                      ${Stats.format_decimal(log.provider_cost_usd || 0)}
                    </td>
                    <td class="text-right text-sm">
                      {Stats.format_ms(log.latency_ms)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div :if={@has_more} class="flex justify-center mt-3">
              <button
                phx-click="load_more"
                class="btn btn-ghost btn-sm"
                id="load-more-supervised-logs"
              >
                Cargar más
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  defp period_label("today"), do: "Hoy"
  defp period_label("7d"), do: "7 días"
  defp period_label("30d"), do: "30 días"
  defp period_label("90d"), do: "90 días"
  defp period_label(_), do: "30 días"

  defp model_names_for(granted_models, service_id, all_models) do
    Map.get(granted_models, service_id, [])
    |> Enum.map(&Enum.find(all_models, fn a -> a.id == &1 end))
    |> Enum.reject(&is_nil/1)
  end
end
