defmodule TokengateWeb.StatsLive do
  @moduledoc """
  Analytics dashboard with drill-down by model and group.

  Three views via `live_action`:
    * `:index`  — overview with top-N tables and KPI cards
    * `:models` — per-model breakdown + drill-down (provider, group, member)
    * `:groups`  — per-group breakdown + drill-down (members, models)

  Periods: Hoy, Esta semana, Este mes, 30d, 90d.

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
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  import TokengateWeb.StatsLive.Index, only: [index: 1]
  import TokengateWeb.StatsLive.Models, only: [models: 1]
  import TokengateWeb.StatsLive.Groups, only: [groups: 1]
  import TokengateWeb.StatsLive.Services, only: [services: 1]
  import TokengateWeb.StatsLive.Member, only: [member: 1]
  import TokengateWeb.StatsLive.Credits, only: [credits: 1]

  import TokengateWeb.StatsHelpers,
    only: [period_label: 1, period_active?: 2, sort_rows: 3]

  # Breakdown assigns whose tables have sortable column headers. The "sort"
  # event re-orders these in memory — see resort_breakdowns/3.
  # Credits tab: budgets reload cadence after a `logs:new` broadcast (same
  # rationale as the old CreditsLive — see its comment block).
  @reload_interval_ms 3_000
  @credits_per_page 10

  @sortable_breakdowns [
    :breakdown_model,
    :breakdown_member,
    :breakdown_group,
    :breakdown_provider,
    :breakdown_service,
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
      |> assign(:member_id, nil)
      |> assign(:sort_field, :request_count)
      |> assign(:sort_direction, :desc)
      |> assign(:hovered_hour, nil)
      |> assign(:stats_loading, true)
      |> assign(:per_page, @credits_per_page)
      |> assign(:shown_counts, %{})
      |> assign(:reload_scheduled, false)
      |> assign(empty_data_assigns())

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = parse_period(params["period"])
    model_filter = params["model_id"]
    group_filter = params["group_id"]
    service_filter = params["service_id"]
    member_id = params["member_id"]

    socket =
      socket
      |> assign(:period, period)
      |> assign(:model_filter, model_filter)
      |> assign(:group_filter, group_filter)
      |> assign(:service_filter, service_filter)
      |> assign(:member_id, member_id)

    socket =
      if socket.assigns.live_action == :credits do
        load_budgets(socket)
      else
        start_data_load(socket)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(today week month 30d 90d) do
    {:noreply, socket |> assign(:period, period) |> start_data_load()}
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
    {:noreply, load_budgets(socket)}
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
      member_id: assigns.member_id,
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

  # Credits tab: coalesce `logs:new` broadcasts into a single budget reload.
  @impl true
  def handle_info({:new_log, _log}, socket) do
    if socket.assigns.live_action == :credits and not socket.assigns.reload_scheduled do
      Process.send_after(self(), :reload_budgets, @reload_interval_ms)
      {:noreply, assign(socket, :reload_scheduled, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:reload_budgets, socket) do
    {:noreply,
     socket
     |> assign(:reload_scheduled, false)
     |> load_budgets()}
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

        maybe_admin_tasks(admin?, opts) ++
          [
            fn -> {:breakdown_model, Rollup.breakdown_by_model(nil, opts)} end,
            fn -> {:breakdown_member, Rollup.breakdown_by_member(nil, opts)} end,
            fn -> {:breakdown_group, breakdown_by_group_if_admin(admin?, opts)} end,
            fn -> {:top_errors, Rollup.top_errors(nil, opts)} end,
            fn -> {:hour_distribution, Rollup.usage_by_hour_of_day(nil, opts)} end,
            fn -> {:hour_usage_stacked, Rollup.usage_by_hour_of_day_stacked(nil, opts)} end,
            fn -> {:model_provider_stacked, Rollup.usage_by_model_provider_stacked(opts)} end,
            fn -> {:busiest_hours, Rollup.busiest_hours(nil, opts)} end,
            fn -> {:busiest_minutes, Rollup.busiest_minutes(nil, opts)} end
          ]

      :models ->
        model_id = params.model_filter

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
          ]
        else
          [fn -> {:breakdown_model, Rollup.breakdown_by_model(nil, opts)} end]
        end

      :groups ->
        group_id = params.group_filter
        admin? = params.user.global_role == "admin"
        allowed? = group_id && group_drilldown_allowed?(params.user, group_id)

        [fn -> {:breakdown_group, breakdown_by_group_if_admin(admin?, opts)} end] ++
          if allowed? do
            [
              fn -> {:breakdown_member, Rollup.breakdown_by_member(group_id, opts)} end,
              fn -> {:breakdown_model, Rollup.breakdown_by_model(group_id, opts)} end,
              fn ->
                {:drilldown_series, Rollup.daily_series_by_model_for_group(group_id, opts)}
              end,
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

      :services ->
        service_id = params.service_filter
        admin? = params.user.global_role == "admin"

        # Services have a dedicated service_id column.
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

      :member ->
        member_id = params.member_id

        allowed? =
          params.user.global_role == "admin" or
            member_id in Accounts.scope_member_ids(params.user)

        if allowed? do
          [
            fn -> {:member, Accounts.get_group_member!(member_id, :with_assoc)} end,
            fn -> {:member_models, Rollup.breakdown_by_model_for_member(member_id, opts)} end
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  # Admin-only infra/org-wide queries on the index view.
  defp maybe_admin_tasks(true, opts) do
    [
      fn -> {:provider_ranking, Rollup.provider_ranking(nil, opts)} end,
      fn -> {:model_ranking, Rollup.model_ranking(nil, opts)} end,
      fn -> {:member_usage_tiers, Rollup.member_usage_tiers(nil, opts)} end,
      fn -> {:peak_concurrency, Rollup.peak_concurrency(nil, opts)} end
    ]
  end

  defp maybe_admin_tasks(false, _opts), do: []

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
      top_errors: [],
      provider_ranking: [],
      model_ranking: [],
      member: nil,
      member_models: [],
      hour_distribution: [],
      hour_usage_stacked: [],
      model_provider_stacked: [],
      busiest_hours: [],
      busiest_minutes: [],
      peak_concurrency: nil,
      member_usage_tiers: [],
      drilldown_series: [],
      drilldown_series_labels: [],
      budgets: [],
      budgets_by_group: %{},
      group_budgets: [],
      inactive_by_group: %{}
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
    opts
    |> apply_stats_filters(params)
    |> Logs.cost_summary()
  end

  defp fetch_summary(%{user: %{global_role: "user"} = user}, opts) do
    memberships = Accounts.list_group_members_for_user(user.id)
    member_ids = Enum.map(memberships, & &1.id)

    opts
    |> Map.new()
    |> Map.put(:group_member_ids, member_ids)
    |> Logs.cost_summary()
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

  ## Credits (budgets) ----------------------------------------------------

  # Whole-page bundle behind a short TTL (same pattern as the old
  # CreditsLive): list_member_budgets preloads every group member and runs
  # 2 Postgres aggregates; inactive_members runs a lifetime MAX(inserted_at)
  # per inactive member. Connected tabs share one computation per TTL window.
  defp load_budgets(socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    bundle =
      DashboardCache.fetch_or_compute({:credits_budgets, timezone}, fn ->
        budgets = Budgets.list_member_budgets(timezone)

        %{
          budgets: budgets,
          budgets_by_group: Enum.group_by(budgets, fn b -> b.member.group.id end),
          group_budgets: Budgets.rollup_group_budgets(budgets),
          inactive_by_group: inactive_members(budgets, timezone)
        }
      end)

    socket
    |> assign(:stats_loading, false)
    |> assign(:budgets, bundle.budgets)
    |> assign(:budgets_by_group, bundle.budgets_by_group)
    |> assign(:group_budgets, bundle.group_budgets)
    |> assign(:inactive_by_group, bundle.inactive_by_group)
  end

  defp inactive_members(budgets, _timezone) do
    inactive =
      budgets
      |> Enum.filter(fn b ->
        Decimal.compare(b.daily_spend_usd, Decimal.new(0)) == :eq and
          Decimal.compare(b.monthly_spend_usd, Decimal.new(0)) == :eq
      end)

    last_requests = Budgets.last_requests_by_member_ids(Enum.map(inactive, & &1.member.id))

    inactive
    |> Enum.map(fn b -> Map.put(b, :last_request_at, Map.get(last_requests, b.member.id)) end)
    |> Enum.group_by(fn b -> b.member.group.id end)
  end

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
