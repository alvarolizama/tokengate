defmodule TokengateWeb.StatsLive do
  @moduledoc """
  Analytics dashboard with drill-down by model, user and group.

  Views via `live_action`:
    * `:live`    — real-time overview (no period selector)
    * `:index`   — overview with top-N tables and KPI cards
    * `:models`  — per-model breakdown + drill-down (provider, user, group)
    * `:services` — per-service breakdown + drill-down (models)
    * `:groups`  — per-group list
    * `:group`   — one group's hub: members, models, daily series
    * `:users`   — per-user consolidated breakdown (all memberships)
    * `:credits` — budgets (calendar counters, no period)

  Periods: Hoy, Esta semana, Este mes, 30d, 90d (all but :live/:credits).

  Scoping by role:
    * admin   — org-wide
    * manager — only groups they manage
    * user    — only their own consumption

  CSV export available via `/stats/export` controller.
  """
  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Budgets
  alias Tokengate.Logs
  alias Tokengate.Logs.Inflight
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.StatsQueries
  alias Tokengate.Periods
  import TokengateWeb.StatsLive.Index, only: [index: 1]
  import TokengateWeb.StatsLive.Models, only: [models: 1]
  import TokengateWeb.StatsLive.Groups, only: [groups: 1]
  import TokengateWeb.StatsLive.Services, only: [services: 1]
  import TokengateWeb.StatsLive.Users, only: [users: 1]
  import TokengateWeb.StatsLive.Providers, only: [providers: 1]
  import TokengateWeb.StatsLive.LiveSection, only: [live: 1]

  import TokengateWeb.StatsHelpers,
    only: [period_label: 1, period_active?: 2, sort_rows: 3]

  alias TokengateWeb.StatsHelpers, as: Stats

  # Breakdown assigns whose tables have sortable column headers. The "sort"
  # event re-orders these in memory — see resort_breakdowns/3.
  # Credits tab: budgets reload cadence after a `logs:new` broadcast (same
  # rationale as the old CreditsLive — see its comment block).
  @reload_interval_ms 3_000

  # "En vivo" tab: cadence of the periodic realtime refresh (matching
  # LogsLive's inflight cadence).
  @live_refresh_interval_ms 3_000

  # "En vivo" feed: how many recent requests to show.
  @live_feed_size 20

  @sortable_breakdowns [
    :breakdown_model,
    :breakdown_member,
    :breakdown_group,
    :breakdown_provider,
    :breakdown_service,
    :breakdown_user,
    :member_models,
    :member_usage_tiers
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Estadísticas · Tokengate")
      |> assign(:period, "today")
      |> assign(:model_filter, nil)
      |> assign(:group_filter, nil)
      |> assign(:service_filter, nil)
      |> assign(:scope_label, scope_label_for(user))
      |> assign(:scope_member_ids, Accounts.scope_member_ids(user))
      |> assign(:group_id, nil)
      |> assign(:sort_field, :request_count)
      |> assign(:sort_direction, :desc)
      |> assign(:list_search, "")
      |> assign(:hovered_hour, nil)
      |> assign(:stats_loading, true)
      |> assign(:per_page, 10)
      |> assign(:shown_counts, %{})
      |> assign(:reload_scheduled, false)
      |> assign_budget_reset()
      |> assign(empty_data_assigns())

    socket =
      if connected?(socket) do
        socket
      else
        # The "En vivo" template reads @streams.live_feed; register the
        # stream so the static (pre-connect) render has the assign.
        stream(socket, :live_feed, [], reset: true)
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
      # Realtime pulse for the "En vivo" tab (broadcast per proxied request
      # by Metrics.Collector) + periodic tick so the page ages gracefully.
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "metrics:updated")
      schedule_clock_tick()
      send(self(), :live_tick)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = parse_period(params["period"])
    model_filter = params["model_id"]
    group_filter = params["group_id"]
    service_filter = params["service_id"]
    # :group action carries the group in the URL path; the other actions
    # clear it (drill-downs keep using ?group_id=).
    group_id =
      case socket.assigns.live_action do
        :group -> params["group_id"] || socket.assigns[:group_id]
        _ -> params["group_id"]
      end

    socket =
      socket
      |> assign(:period, period)
      |> assign(:model_filter, model_filter)
      |> assign(:group_filter, group_filter)
      |> assign(:service_filter, service_filter)
      |> assign(:group_id, group_id)
      # Cada sección tiene su propio listado: el filtro de la anterior no
      # aplica y escondería filas sin que se vea por qué.
      |> assign(:list_search, "")

    socket =
      case socket.assigns.live_action do
        :live -> load_live_data(socket)
        _ -> start_data_load(socket)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(today week month 30d 90d) do
    {:noreply, socket |> assign(:period, period) |> start_data_load()}
  end

  # Buscador de los listados rankeados (Users, Models, Providers). El texto
  # vive en el socket y las secciones filtran sus propias filas en el render:
  # no toca la DB ni las claves del DashboardCache.
  def handle_event("filter_list", %{"value" => query}, socket) do
    {:noreply, assign(socket, :list_search, query || "")}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)

    {sort_field, sort_direction} =
      if socket.assigns.sort_field == field do
        {field, toggle_direction(socket.assigns.sort_direction)}
      else
        {field, :desc}
      end

    {:noreply,
     socket
     |> assign(:sort_field, sort_field)
     |> assign(:sort_direction, sort_direction)
     |> resort_breakdowns(sort_field, sort_direction)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, start_data_load(socket)}
  end

  def handle_event("show_more", %{"group-id" => group_id}, socket) do
    shown = Map.get(socket.assigns.shown_counts, group_id, socket.assigns.per_page)

    {:noreply,
     assign(
       socket,
       :shown_counts,
       Map.put(socket.assigns.shown_counts, group_id, shown + socket.assigns.per_page)
     )}
  end

  def handle_event("hour_hover", %{"hour" => hour}, socket) do
    hour = String.to_integer(hour)
    {:noreply, assign(socket, :hovered_hour, hour)}
  end

  def handle_event("hour_leave", _params, socket) do
    {:noreply, assign(socket, :hovered_hour, nil)}
  end

  defp toggle_direction(:asc), do: :desc
  defp toggle_direction(:desc), do: :asc

  # Re-apply sort_rows to every breakdown list already loaded in the socket.
  # Sorting is client-side over the current period's rows — no need to hit the
  # DB again. Only assigns that exist are touched (each live_action loads a
  # different subset).
  defp resort_breakdowns(socket, field, direction) do
    Enum.reduce(@sortable_breakdowns, socket, fn key, acc ->
      case acc.assigns[key] do
        nil -> acc
        rows -> assign(acc, key, sort_rows(rows, field, direction))
      end
    end)
  end

  ## Data loading ---------------------------------------------------------

  # Kick off an async data load. The socket renders right away with the
  # previous period's data (or empty values on first mount) plus an inline
  # loading indicator; when every query finishes, the new data lands in one
  # diff via handle_info/2. Switching periods quickly cancels the in-flight
  # load automatically.
  defp start_data_load(socket) do
    assigns = socket.assigns

    params = %{
      user: assigns.current_user,
      period: assigns.period,
      model_filter: assigns.model_filter,
      group_filter: assigns.group_filter,
      service_filter: assigns.service_filter,
      group_id: assigns.group_id,
      scope_member_ids: assigns.scope_member_ids,
      live_action: assigns.live_action,
      timezone: assigns[:timezone] || "Etc/UTC",
      sort_field: assigns.sort_field,
      sort_direction: assigns.sort_direction
    }

    socket
    |> assign(:stats_loading, true)
    |> start_async(:stats_data, fn -> compute_data_assigns(params) end)
  end

  @impl true
  def handle_async(:stats_data, {:ok, data}, socket) do
    socket =
      socket
      |> assign(:stats_loading, false)
      |> assign(empty_data_assigns())
      |> assign(data)

    {:noreply, socket}
  end

  def handle_async(:stats_data, {:exit, reason}, socket) do
    require Logger
    Logger.warning("stats data load failed: #{inspect(reason)}")

    {:noreply, assign(socket, :stats_loading, false)}
  end

  # `logs:new` broadcast — route by tab:
  #   * live: prepend to the feed + refresh the pulse
  #   * overview: coalesce into a single reload so the org budget bar and
  #     KPIs track spend as it happens
  @impl true
  def handle_info({:new_log, log}, socket) do
    case socket.assigns.live_action do
      :live ->
        {:noreply,
         socket
         |> stream_insert(:live_feed, log, at: 0, limit: @live_feed_size)
         |> assign(:pulse, Logs.realtime_summary(%{}))
         |> assign(:last_sync_at, DateTime.utc_now())}

      :index ->
        if not socket.assigns.reload_scheduled do
          Process.send_after(self(), :reload_budgets, @reload_interval_ms)
          {:noreply, assign(socket, :reload_scheduled, true)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(:reload_budgets, socket) do
    {:noreply,
     socket
     |> assign(:reload_scheduled, false)
     |> start_data_load()}
  end

  ## "En vivo" tab ----------------------------------------------------------

  # Realtime refresh: metrics_updated is broadcast on every proxied request;
  # coalesce into one reload per @live_refresh_interval_ms. The periodic
  # :live_tick keeps the page moving even with zero traffic (chart shifts,
  # "hace Ns" ages).
  def handle_info({:metrics_updated, _lite}, socket) do
    if socket.assigns.live_action == :live and not socket.assigns.reload_scheduled do
      Process.send_after(self(), :reload_live, @live_refresh_interval_ms)
      {:noreply, assign(socket, :reload_scheduled, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:reload_live, socket) do
    if socket.assigns.live_action == :live do
      {:noreply,
       socket
       |> assign(:reload_scheduled, false)
       |> load_live_data()}
    else
      {:noreply, assign(socket, :reload_scheduled, false)}
    end
  end

  def handle_info(:live_tick, socket) do
    if socket.assigns.live_action == :live do
      Process.send_after(self(), :live_tick, @live_refresh_interval_ms)

      {:noreply, assign(socket, :inflight_count, Inflight.count())}
    else
      {:noreply, socket}
    end
  end

  # Minute-aligned clock tick for the budget-reset countdown. The countdown
  # is the only thing on /stats that has to move with zero traffic (the
  # "En vivo" 3s tick and the Resumen's `logs:new` reload both stall when the
  # proxy is idle), and it only changes once a minute, so we wake on the
  # minute boundary instead of polling. Re-assigning an unchanged value is a
  # no-op in `assign/3`, so this costs a re-render only when the label
  # actually changes (or on the midnight rollover).
  def handle_info(:clock_tick, socket) do
    schedule_clock_tick()
    {:noreply, assign_budget_reset(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Pure orchestration: no socket, no assigns — everything runs off plain
  # values so it can execute inside an async task (queries in parallel).
  defp compute_data_assigns(params) do
    %{from: from, to: to} = Periods.period_bounds(params.period, params.timezone)
    opts = [from: from, to: to, timezone: params.timezone]

    summary_task = fn -> {:metrics, summary_to_metrics(fetch_summary(params, opts))} end

    prev_summary_task = fn ->
      prev = previous_summary(params, params.period, params.timezone)
      {:prev_metrics, summary_to_metrics(prev)}
    end

    [summary_task, prev_summary_task | breakdown_tasks(params, opts)]
    |> run_parallel()
    |> Map.new()
    |> apply_sorting(params)
    |> merge_prev_metrics()
  end

  # Fetch the previous period's summary for delta comparison.
  defp previous_summary(params, period, timezone) do
    %{from: prev_from, to: prev_to} = Periods.previous_period_bounds(period, timezone)
    prev_opts = [from: prev_from, to: prev_to, timezone: timezone]
    fetch_summary(params, prev_opts)
  end

  # Merge prev_metrics into the :metrics map as delta percentages.
  defp merge_prev_metrics(%{metrics: metrics, prev_metrics: prev} = data) do
    Map.put(data, :metrics, Map.put(metrics, :deltas, compute_deltas(metrics, prev)))
  end

  defp merge_prev_metrics(data), do: data

  # Run every query function concurrently and collect results in order.
  # Queries share the Repo pool, so wall time is pool rounds, not the sum of
  # every query — this is what makes period switching feel fast.
  defp run_parallel(fun_list) do
    fun_list
    |> Task.async_stream(fn fun -> fun.() end, timeout: :infinity, zip_input_on_exit: true)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp summary_to_metrics(summary) do
    %{
      requests_total: summary.request_count,
      cost_usd: summary.total_cost_usd,
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
      cache_read_tokens: Map.get(summary, :total_cache_read_tokens, 0),
      cache_creation_tokens: Map.get(summary, :total_cache_creation_tokens, 0),
      avg_tps: Map.get(summary, :avg_tps)
    }
  end

  # Delta percentages for KPI comparison vs the previous period.
  # Returns nil when the previous value was zero (can't compute % change).
  defp compute_deltas(current, prev) do
    %{
      requests_total: pct_delta(current.requests_total, prev.requests_total),
      cost_usd: decimal_pct_delta(current.cost_usd, prev.cost_usd),
      prompt_tokens: pct_delta(current.prompt_tokens, prev.prompt_tokens),
      completion_tokens: pct_delta(current.completion_tokens, prev.completion_tokens)
    }
  end

  defp pct_delta(_current, 0), do: nil
  defp pct_delta(_current, nil), do: nil

  defp pct_delta(current, prev) when is_number(prev) and prev != 0 do
    Float.round((current - prev) / abs(prev) * 100, 1)
  end

  defp decimal_pct_delta(_current, %Decimal{coef: 0}), do: nil
  defp decimal_pct_delta(_current, nil), do: nil

  defp decimal_pct_delta(current, prev) do
    if Decimal.equal?(prev, Decimal.new(0)) do
      nil
    else
      current
      |> Decimal.sub(prev)
      |> Decimal.div(Decimal.abs(prev))
      |> Decimal.mult(Decimal.from_float(100.0))
      |> Decimal.round(1)
      |> Decimal.to_float()
    end
  end

  # Each task returns {assign_key, rows} so results can be applied without
  # caring about completion order.
  defp breakdown_tasks(params, opts) do
    opts = Keyword.put(opts, :member_ids, params.scope_member_ids)

    case params.live_action do
      :index ->
        admin? = params.user.global_role == "admin"

        # El Resumen ya NO carga tops/rankings/tiers: se movieron a las stats
        # de cada sección (models/groups/providers) para no recomputar los
        # agregados caros (percentile_cont, sweep de concurrencia) en cada
        # recarga del broadcast `logs:new`, que re-lanza el bundle completo.
        #
        # El card "Tope diario global" mide la MISMA ventana que el
        # kill-switch (día UTC) cuando el período es "hoy": así la barra y el
        # badge comparan gasto real contra el cap real, igual que
        # Mantenimiento. En ventanas más largas muestra el gasto del período
        # (vía opts.from) sin barra — el tope aplica por día UTC y no hay nada
        # contra lo que compararlo. Nunca el contador ETS del proxy: ese
        # incluye holds en vuelo y "respira".
        index_admin_tasks(admin?, opts) ++
          [
            fn ->
              from = if params.period == "today", do: nil, else: opts[:from]
              {:org_budget, Budgets.global_daily_budget_summary(from)}
            end,
            fn -> {:hour_usage_stacked, Rollup.usage_by_hour_of_day_stacked(nil, opts)} end,
            fn -> {:model_provider_stacked, Rollup.usage_by_model_provider_stacked(opts)} end,
            fn -> {:busiest_hours, Rollup.busiest_hours(nil, opts)} end,
            fn -> {:busiest_minutes, Rollup.busiest_minutes(nil, opts)} end
          ]

      :models ->
        model_id = params.model_filter
        # Ranking de modelos movido del Resumen (:index).
        ranking_task = fn -> {:model_ranking, Rollup.model_ranking(nil, opts)} end

        if model_id do
          [
            fn -> {:breakdown_model, Rollup.breakdown_by_model(nil, opts)} end,
            fn ->
              {:breakdown_provider, Rollup.breakdown_by_provider_for_model(model_id, opts)}
            end,
            fn ->
              {:breakdown_group, breakdown_group_for_model(params.user, model_id, opts)}
            end,
            fn ->
              {:breakdown_member, Rollup.breakdown_by_member_for_model(model_id, opts)}
            end,
            fn ->
              {:drilldown_series, Rollup.daily_series_by_provider_for_model(model_id, opts)}
            end,
            fn ->
              {:drilldown_series_labels,
               Rollup.daily_series_by_provider_for_model(model_id, opts)
               |> Enum.map(& &1.label)
               |> Enum.uniq()
               |> Enum.sort()}
            end
          ] ++ [ranking_task]
        else
          [
            fn -> {:breakdown_model, Rollup.breakdown_by_model(nil, opts)} end,
            ranking_task
          ]
        end

      :providers ->
        # Sección Infra nueva: destino del ranking de proveedores.
        [fn -> {:provider_ranking, Rollup.provider_ranking(nil, opts)} end]

      :groups ->
        admin? = params.user.global_role == "admin"

        base =
          [
            fn -> {:breakdown_group, breakdown_by_group_if_admin(admin?, opts)} end
          ] ++
            if admin? do
              [
                fn -> {:group_budgets, Budgets.list_group_budgets(params.timezone)} end,
                fn -> {:member_usage_tiers, Rollup.member_usage_tiers(nil, opts)} end
              ]
            else
              []
            end

        # Drill-down (?group_id=) shares the template with :group and
        # needs the group record for the breadcrumb.
        case params.group_filter do
          nil ->
            base

          group_id ->
            if group_drilldown_allowed?(params.user, group_id) do
              [fn -> {:group, Accounts.get_group!(group_id)} end | base]
            else
              base
            end
        end

      :group ->
        group_id = params.group_id
        allowed? = group_drilldown_allowed?(params.user, group_id)

        if allowed? do
          [
            fn -> {:group, Accounts.get_group!(group_id)} end,
            fn ->
              {:group_budget,
               Budgets.list_group_budgets(params.timezone) |> find_group_budget(group_id)}
            end,
            fn -> {:breakdown_member, Rollup.breakdown_by_member(group_id, opts)} end,
            fn -> {:breakdown_model, Rollup.breakdown_by_model(group_id, opts)} end,
            fn -> {:drilldown_series, Rollup.daily_series_by_model_for_group(group_id, opts)} end,
            fn ->
              {:drilldown_series_labels,
               Rollup.daily_series_by_model_for_group(group_id, opts)
               |> Enum.map(& &1.label)
               |> Enum.uniq()
               |> Enum.sort()}
            end
          ]
        else
          []
        end

      :users ->
        [
          fn -> {:breakdown_user, Rollup.breakdown_by_user(opts)} end,
          fn -> {:budgets_by_user, Budgets.spend_by_user(params.timezone)} end
        ]

      :services ->
        service_id = params.service_filter
        admin? = params.user.global_role == "admin"

        # Services have a dedicated service_id column.
        [fn -> {:service_budgets, Budgets.list_service_budgets()} end] ++
          [fn -> {:breakdown_service, breakdown_by_service_if_admin(admin?, opts)} end] ++
          if service_id && admin? do
            [
              fn ->
                {:breakdown_model,
                 Rollup.breakdown_by_model(nil, Keyword.put(opts, :service_id, service_id))}
              end,
              fn ->
                {:drilldown_series, Rollup.daily_series_by_model_for_service(service_id, opts)}
              end,
              fn ->
                {:drilldown_series_labels,
                 Rollup.daily_series_by_model_for_service(service_id, opts)
                 |> Enum.map(& &1.label)
                 |> Enum.uniq()
                 |> Enum.sort()}
              end
            ]
          else
            []
          end

      _ ->
        []
    end
  end

  # Admin-only infra/org-wide queries on the index view. Ahora el Resumen solo
  # conserva el pico de concurrencia (admin): rankings y tiers viven en las
  # secciones models / groups / providers.
  defp index_admin_tasks(true, opts) do
    [fn -> {:peak_concurrency, Rollup.peak_concurrency(nil, opts)} end]
  end

  defp index_admin_tasks(false, _opts), do: []

  # Picks a single group's budget row out of the group rollup.
  defp find_group_budget(rows, group_id) do
    Enum.find(rows, fn row -> row.group.id == group_id end)
  end

  defp apply_sorting(data, %{sort_field: field, sort_direction: direction}) do
    Enum.reduce(@sortable_breakdowns, data, fn key, acc ->
      case acc do
        %{^key => rows} -> Map.put(acc, key, sort_rows(rows, field, direction))
        _ -> acc
      end
    end)
  end

  # Empty values for every data assign — used on mount so the first render
  # (while the async load runs) shows empty states instead of stale assigns.
  defp empty_data_assigns do
    %{
      metrics: empty_metrics(),
      breakdown_model: [],
      breakdown_member: [],
      breakdown_group: [],
      breakdown_provider: [],
      breakdown_service: [],
      breakdown_user: [],
      provider_ranking: [],
      model_ranking: [],
      group: nil,
      member: nil,
      member_models: [],
      hour_usage_stacked: [],
      model_provider_stacked: [],
      busiest_hours: [],
      busiest_minutes: [],
      peak_concurrency: nil,
      member_usage_tiers: [],
      drilldown_series: [],
      drilldown_series_labels: [],
      org_budget: nil,
      budgets_by_user: %{},
      service_budgets: [],
      group_budgets: [],
      group_budget: nil
    }
  end

  ## Scoping helpers ------------------------------------------------------

  defp group_drilldown_allowed?(user, group_id) do
    case Accounts.scope_group_ids(user) do
      nil -> true
      group_ids -> group_id in group_ids
    end
  end

  # Group table for a model drill-down: admins see every group; managers only
  # groups they manage; regular users don't see group-level data at all.
  defp breakdown_group_for_model(user, model_id, opts) do
    case Accounts.scope_group_ids(user) do
      nil -> Rollup.breakdown_by_group_for_model(model_id, opts)
      [] -> []
    end
  end

  defp breakdown_by_group_if_admin(true, opts), do: Rollup.breakdown_by_group(opts)
  defp breakdown_by_group_if_admin(false, _opts), do: []

  defp breakdown_by_service_if_admin(true, opts), do: Rollup.breakdown_by_service(opts)
  defp breakdown_by_service_if_admin(false, _opts), do: []

  defp fetch_summary(%{user: %{global_role: "admin"}} = params, opts) do
    # Hybrid read: rollup for the bulk of the window + raw tail (last 3h)
    # — see Tokengate.Metrics.StatsQueries. Falls back to raw when the
    # window is recent-only or the rollup flag is off.
    opts
    |> apply_stats_filters(params)
    |> StatsQueries.summary()
  end

  defp fetch_summary(%{user: %{global_role: "user"} = user}, opts) do
    memberships = Accounts.list_group_members_for_user(user.id)
    member_ids = Enum.map(memberships, & &1.id)

    opts
    |> Map.new()
    |> Map.put(:group_member_ids, member_ids)
    |> StatsQueries.summary()
  end

  defp fetch_summary(_params, _opts), do: empty_summary()

  # Build a filter map from the active stats page filter so cost_summary
  # returns data scoped to the selected model / group / service.
  defp apply_stats_filters(opts, params) do
    base = Map.new(opts)

    cond do
      params.model_filter ->
        Map.put(base, :model_id, params.model_filter)

      params.group_filter ->
        Map.put(base, :group_id, params.group_filter)

      params.service_filter ->
        Map.put(base, :service_id, params.service_filter)

      true ->
        base
    end
  end

  ## "En vivo" data ---------------------------------------------------------

  # Countdown to the global kill-switch reset, split into hours/minutes so the
  # template can render the `:` as its own blinking element. Minute-granular,
  # so a per-minute wall-clock tick almost always reassigns identical values
  # and `assign/3` no-ops — the diff goes out only when the label actually
  # changes, not on every tick.
  #
  # The countdown is a plain duration (timezone-independent); `reset_at` is the
  # same instant, which the label renders in the selected zone so the user
  # reads the reset on their own clock.
  defp assign_budget_reset(socket) do
    reset_at = Periods.next_utc_day_start(Periods.now_utc())
    {hours, minutes} = Stats.countdown_parts(reset_at)

    socket
    |> assign(:budget_reset_hours, hours)
    |> assign(:budget_reset_minutes, minutes)
    |> assign(:budget_reset_at, reset_at)
  end

  # Wakes just after the wall-clock minute turns, so the countdown label is
  # never more than a second stale. Skew between the BEAM and the browser
  # clock would otherwise drift the label off the minute boundary.
  defp schedule_clock_tick do
    ms = 60_000 - rem(System.system_time(:millisecond), 60_000)
    Process.send_after(self(), :clock_tick, ms)
  end

  # One bundled realtime refresh. All queries are cheap (index range scans
  # over the last hour/day) and shared across connected live tabs via the
  # DashboardCache TTL so a busy proxy doesn't multiply Postgres load.
  defp load_live_data(socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    bundle =
      DashboardCache.fetch_or_compute({:stats_live, timezone}, fn ->
        # KPIs "Hoy" = día UTC (misma ventana que el kill-switch y que el
        # card de tope de arriba) — no el día local del usuario.
        today_metrics = Logs.today_summary("Etc/UTC")

        %{
          pulse: Logs.realtime_summary(%{}),
          today_metrics: today_metrics,
          minute_series: Logs.requests_per_minute(60),
          # "Hoy por hora · por proveedor": un solo agregado (hora ×
          # proveedor) sobre la partición del día UTC, sin joins.
          day_by_hour: Logs.today_usage_by_hour_provider(),
          # Gasto real del día UTC — el mismo número que muestra Mantenimiento
          # — más cap y exentos del kill-switch. Día UTC y no local: el cap
          # resetea a las 00:00 UTC, así que barra, % y countdown tienen que
          # medir la misma ventana. Nada de contador ETS (holds).
          org_budget: Budgets.global_daily_budget_summary()
        }
      end)

    feed_logs = Logs.list_logs(%{limit: @live_feed_size})

    minute_series = bundle.minute_series

    socket
    |> assign(:stats_loading, false)
    |> assign(:pulse, bundle.pulse)
    |> assign(:today_metrics, bundle.today_metrics)
    |> assign(:minute_series, minute_series)
    |> assign(:minute_series_max, minute_requests_max(minute_series))
    |> assign(:minute_tokens_max, minute_tokens_max(minute_series))
    |> assign(:minute_cost_max, minute_cost_max(minute_series))
    |> assign(:org_budget, bundle.org_budget)
    |> assign(:inflight_count, Inflight.count())
    |> assign(:day_by_hour, bundle.day_by_hour)
    |> assign(:last_sync_at, DateTime.utc_now())
    |> stream(:live_feed, feed_logs, reset: true)
  end

  # Per-series maxima for the three "En vivo" bar charts. All three read the
  # same 60-bucket series already in hand — no extra query.
  defp minute_requests_max(series), do: series |> Enum.map(& &1.request_count) |> max_or_zero()

  defp minute_tokens_max(series) do
    series
    |> Enum.map(&(&1.prompt_tokens + &1.completion_tokens))
    |> max_or_zero()
  end

  defp minute_cost_max(series) do
    series
    |> Enum.map(&Decimal.to_float(&1.cost_usd))
    |> Enum.max(fn -> 0.0 end)
  end

  defp max_or_zero([]), do: 0
  defp max_or_zero(list), do: Enum.max(list)

  ## Helpers --------------------------------------------------------------

  defp parse_period(nil), do: "today"
  defp parse_period(period) when period in ~w(today week month 30d 90d), do: period
  defp parse_period(_), do: "today"

  defp empty_metrics do
    %{
      requests_total: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      avg_tps: nil,
      deltas: %{
        requests_total: nil,
        cost_usd: nil,
        prompt_tokens: nil,
        completion_tokens: nil
      }
    }
  end

  defp empty_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      request_count: 0,
      avg_tps: nil
    }
  end

  defp scope_label_for(%{global_role: "admin"}), do: "Organización completa"

  defp scope_label_for(%{global_role: "user"}), do: "Tus consumos"

  defp scope_label_for(_), do: "—"
end
