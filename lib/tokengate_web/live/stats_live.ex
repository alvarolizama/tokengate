defmodule TokengateWeb.StatsLive do
  @moduledoc """
  Analytics dashboard with drill-down by model and team.

  Three views via `live_action`:
    * `:index`  — overview with top-N tables and KPI cards
    * `:models` — per-model breakdown + drill-down (provider, team, member)
    * `:teams`  — per-team breakdown + drill-down (members, models)

  Periods: Hoy, 7d, 30d, 90d.

  Scoping by role:
    * admin   — org-wide
    * manager — only teams they manage
    * user    — only their own consumption

  CSV export available via `/dashboard/stats/export` controller.
  """
  use TokengateWeb, :live_view

  import TokengateWeb.KpiHelpers, only: [kpi_cards: 1]

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods

  # Breakdown assigns whose tables have sortable column headers. The "sort"
  # event re-orders these in memory — see resort_breakdowns/3.
  @sortable_breakdowns [
    :breakdown_model,
    :breakdown_member,
    :breakdown_team,
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
      |> assign(:team_filter, nil)
      |> assign(:service_filter, nil)
      |> assign(:scope_label, scope_label_for(user))
      |> assign(:scope_member_ids, Accounts.scope_member_ids(user))
      |> assign(:member_id, nil)
      |> assign(:sort_field, :request_count)
      |> assign(:sort_direction, :desc)
      |> assign(:hovered_hour, nil)
      |> assign(:stats_loading, true)
      |> assign(empty_data_assigns())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = parse_period(params["period"])
    model_filter = params["model_id"]
    team_filter = params["team_id"]
    service_filter = params["service_id"]
    member_id = params["member_id"]

    socket =
      socket
      |> assign(:period, period)
      |> assign(:model_filter, model_filter)
      |> assign(:team_filter, team_filter)
      |> assign(:service_filter, service_filter)
      |> assign(:member_id, member_id)
      |> start_data_load()

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(today 7d 30d 90d) do
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
      team_filter: assigns.team_filter,
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

  # Pure orchestration: no socket, no assigns — everything runs off plain
  # values so it can execute inside an async task (queries in parallel).
  defp compute_data_assigns(params) do
    %{from: from, to: to} = Periods.period_bounds(params.period, params.timezone)
    opts = [from: from, to: to, timezone: params.timezone]

    summary_task = fn -> {:metrics, summary_to_metrics(fetch_summary(params, opts))} end

    [summary_task | breakdown_tasks(params, opts)]
    |> run_parallel()
    |> Map.new()
    |> apply_sorting(params)
  end

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
      avg_tps: Map.get(summary, :avg_tps)
    }
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
            fn -> {:breakdown_team, breakdown_by_team_if_admin(admin?, opts)} end,
            fn -> {:top_errors, Rollup.top_errors(nil, opts)} end,
            fn -> {:hour_distribution, Rollup.usage_by_hour_of_day(nil, opts)} end,
            fn -> {:hour_usage_stacked, Rollup.usage_by_hour_of_day_stacked(nil, opts)} end,
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
              {:breakdown_team, breakdown_team_for_model(params.user, model_id, opts)}
            end,
            fn ->
              {:breakdown_member, Rollup.breakdown_by_member_for_model(model_id, opts)}
            end
          ]
        else
          [fn -> {:breakdown_model, Rollup.breakdown_by_model(nil, opts)} end]
        end

      :teams ->
        team_id = params.team_filter
        admin? = params.user.global_role == "admin"
        allowed? = team_id && team_drilldown_allowed?(params.user, team_id)

        [fn -> {:breakdown_team, breakdown_by_team_if_admin(admin?, opts)} end] ++
          if allowed? do
            [
              fn -> {:breakdown_member, Rollup.breakdown_by_member(team_id, opts)} end,
              fn -> {:breakdown_model, Rollup.breakdown_by_model(team_id, opts)} end
            ]
          else
            []
          end

      :services ->
        service_id = params.service_filter
        admin? = params.user.global_role == "admin"

        # Services are virtual team members — filter by team_member_id, not team_id.
        [fn -> {:breakdown_service, breakdown_by_service_if_admin(admin?, opts)} end] ++
          if service_id && admin? do
            [
              fn ->
                {:breakdown_model,
                 Rollup.breakdown_by_model(nil, Keyword.put(opts, :team_member_id, service_id))}
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
            fn -> {:member, Accounts.get_team_member!(member_id, :with_assoc)} end,
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
      breakdown_team: [],
      breakdown_provider: [],
      breakdown_service: [],
      top_errors: [],
      provider_ranking: [],
      model_ranking: [],
      member: nil,
      member_models: [],
      hour_distribution: [],
      hour_usage_stacked: [],
      busiest_hours: [],
      busiest_minutes: [],
      peak_concurrency: nil,
      member_usage_tiers: []
    }
  end

  ## Scoping helpers ------------------------------------------------------

  defp team_drilldown_allowed?(user, team_id) do
    case Accounts.scope_team_ids(user) do
      nil -> true
      team_ids -> team_id in team_ids
    end
  end

  # Team table for a model drill-down: admins see every team; managers only
  # teams they manage; regular users don't see team-level data at all.
  defp breakdown_team_for_model(user, model_id, opts) do
    case Accounts.scope_team_ids(user) do
      nil -> Rollup.breakdown_by_team_for_model(model_id, opts)
      [] -> []
    end
  end

  defp breakdown_by_team_if_admin(true, opts), do: Rollup.breakdown_by_team(opts)
  defp breakdown_by_team_if_admin(false, _opts), do: []

  defp breakdown_by_service_if_admin(true, opts), do: Rollup.breakdown_by_service(opts)
  defp breakdown_by_service_if_admin(false, _opts), do: []

  defp fetch_summary(%{user: %{global_role: "admin"}} = params, opts) do
    opts
    |> apply_stats_filters(params)
    |> Logs.cost_summary()
  end

  defp fetch_summary(%{user: %{global_role: "user"} = user}, opts) do
    memberships = Accounts.list_team_members_for_user(user.id)
    member_ids = Enum.map(memberships, & &1.id)

    opts
    |> Map.new()
    |> Map.put(:team_member_ids, member_ids)
    |> Logs.cost_summary()
  end

  defp fetch_summary(_params, _opts), do: empty_summary()

  # Build a filter map from the active stats page filter so cost_summary
  # returns data scoped to the selected model / team / service.
  defp apply_stats_filters(opts, params) do
    base = Map.new(opts)

    cond do
      params.model_filter ->
        Map.put(base, :model_alias_id, params.model_filter)

      params.team_filter ->
        Map.put(base, :team_id, params.team_filter)

      params.service_filter ->
        Map.put(base, :team_member_id, params.service_filter)

      true ->
        base
    end
  end

  ## Helpers --------------------------------------------------------------

  defp parse_period(nil), do: "today"
  defp parse_period(period) when period in ~w(today 7d 30d 90d), do: period
  defp parse_period(_), do: "today"

  defp empty_metrics do
    %{
      requests_total: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      avg_tps: nil
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

  ## Template helpers -----------------------------------------------------
  def format_decimal(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  def format_decimal(n) when is_number(n), do: to_string(n)
  def format_decimal(_), do: "0"

  def format_number(n) when is_integer(n), do: with_thousands_separator(n)
  def format_number(n) when is_float(n), do: Float.to_string(n)
  def format_number(_), do: "0"

  @doc "Compact notation for big counters: 32.7K, 1.2M, 3.4B."
  def format_compact(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 1)}B"

  def format_compact(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_compact(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  def format_compact(n) when is_integer(n), do: Integer.to_string(n)
  def format_compact(n) when is_float(n), do: format_compact(trunc(n))
  def format_compact(_), do: "0"

  defp with_thousands_separator(n) do
    digits = Integer.to_string(abs(n))

    grouped =
      digits
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    if n < 0, do: "-" <> grouped, else: grouped
  end

  def format_tps(nil), do: "—"
  def format_tps(n) when is_float(n), do: Float.round(n, 1) |> Float.to_string()
  def format_tps(n) when is_integer(n), do: to_string(n)

  def period_label("today"), do: "Hoy"
  def period_label("7d"), do: "7 días"
  def period_label("30d"), do: "30 días"
  def period_label("90d"), do: "90 días"
  def period_label(_), do: "7 días"

  def period_active?(current, target), do: current == target

  def has_data?([]), do: false
  def has_data?(_), do: true

  def format_ms(nil), do: "—"
  def format_ms(ms) when is_integer(ms), do: "#{format_number(ms)} ms"
  def format_ms(_), do: "—"

  def format_percent(rate) when is_float(rate),
    do: "#{:erlang.float_to_binary(rate * 100, decimals: 1)}%"

  def format_percent(_), do: "—"

  @doc "Compute a total row from a breakdown list for display in table footers."
  def breakdown_total([]), do: nil

  def breakdown_total(rows) when is_list(rows) do
    %{
      request_count: Enum.reduce(rows, 0, &(&1.request_count + &2)),
      cost_usd: Enum.reduce(rows, Decimal.new(0), fn r, acc -> Decimal.add(acc, r.cost_usd) end),
      prompt_tokens: Enum.reduce(rows, 0, &(&1.prompt_tokens + &2)),
      completion_tokens: Enum.reduce(rows, 0, &(&1.completion_tokens + &2))
    }
  end

  @doc "Count distinct providers (by model_provider_id) in a provider breakdown."
  def distinct_providers(rows) when is_list(rows) do
    rows |> Enum.map(& &1.model_provider_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
  end

  @doc "Count distinct users (by user_email) in a member breakdown."
  def distinct_users(rows) when is_list(rows) do
    rows |> Enum.map(& &1.user_email) |> Enum.uniq() |> length()
  end

  def tier_badge_class("S"), do: "badge-success"
  def tier_badge_class("A"), do: "badge-info"
  def tier_badge_class("B"), do: "badge-warning"
  def tier_badge_class("C"), do: "badge-warning badge-outline"
  def tier_badge_class("D"), do: "badge-error"
  def tier_badge_class("alto"), do: "badge-error"
  def tier_badge_class("regular"), do: "badge-warning"
  def tier_badge_class("bajo"), do: "badge-ghost"
  def tier_badge_class(_), do: "badge-ghost"

  def hour_label(hour) when hour in 0..23, do: "#{pad2(hour)}:00"

  def error_class_label(status) when status >= 400 and status < 500, do: "4xx cliente"
  def error_class_label(status) when status >= 500, do: "5xx servidor"
  def error_class_label(_), do: "—"

  def error_class_badge(status) when status >= 400 and status < 500, do: "badge-warning"
  def error_class_badge(status) when status >= 500, do: "badge-error"
  def error_class_badge(_), do: "badge-ghost"

  def hour_distribution_max(rows) do
    rows |> Enum.map(& &1.request_count) |> Enum.max(fn -> 0 end)
  end

  def hour_usage_stacked_max(rows) do
    rows |> Enum.map(& &1.total_requests) |> Enum.max(fn -> 0 end)
  end

  @doc """
  Altura de barra en % usando escala raíz cuadrada.

  Las distribuciones por hora tienen picos muy marcados (horas laborales)
  y valles casi en cero (madrugada). Con escala lineal las barras chicas
  se vuelven invisibles; sqrt comprime los picos y levanta los valles,
  manteniendo el orden relativo.
  """
  def hour_usage_bar_height(requests, max) when max > 0 do
    pct = :math.sqrt(requests / max) * 100
    max(Float.round(pct, 1), 8.0)
  end

  def hour_usage_bar_height(_requests, _max), do: 0

  @doc """
  "Nice number" para ticks del eje Y (1, 2, 5 × 10^n).
  """
  def nice_ceiling(value) when value <= 0, do: 10

  def nice_ceiling(value) do
    exp = :math.log10(value) |> Float.floor() |> round()
    base = :math.pow(10, exp)
    fraction = value / base

    nice_fraction =
      cond do
        fraction <= 1 -> 1
        fraction <= 2 -> 2
        fraction <= 5 -> 5
        true -> 10
      end

    round(nice_fraction * base)
  end

  @doc "Genera `count` ticks (sin incluir 0) hasta un techo 'nice' para el eje Y."
  def y_axis_ticks(max, count \\ 3) do
    ceiling = nice_ceiling(max)

    1..count
    |> Enum.map(fn i -> round(ceiling * i / count) end)
    |> Enum.uniq()
  end

  def pay_per_token_requests(hour_row) do
    hour_row.models
    |> Enum.filter(&(&1.billing_mode == "pay_per_token"))
    |> Enum.reduce(0, &(&1.requests + &2))
  end

  def pay_per_token_pct(hour_row) do
    total = hour_row.total_requests
    ppt = pay_per_token_requests(hour_row)

    if total > 0 do
      Float.round(ppt / total * 100, 1)
    else
      0.0
    end
  end

  def model_color(index) do
    colors = [
      "bg-primary",
      "bg-secondary",
      "bg-accent",
      "bg-success",
      "bg-warning",
      "bg-error",
      "bg-info",
      "bg-neutral"
    ]

    Enum.at(colors, rem(index, length(colors)))
  end

  def top_models_from_stacked(rows) do
    rows
    |> Enum.flat_map(& &1.models)
    |> Enum.group_by(& &1.model)
    |> Enum.map(fn {model, entries} ->
      total_requests = Enum.reduce(entries, 0, &(&1.requests + &2))

      total_cost =
        Enum.reduce(entries, Decimal.new(0), fn e, acc -> Decimal.add(acc, e.cost_usd) end)

      %{model: model, requests: total_requests, cost_usd: total_cost}
    end)
    |> Enum.sort_by(& &1.requests, :desc)
    |> Enum.take(8)
  end

  def model_segments(hour_row, all_models) do
    hour_total = hour_row.total_requests

    if hour_total <= 0 do
      []
    else
      # 1. Segmento included (gris) — siempre al fondo
      included_segment =
        if hour_row.included_requests > 0 do
          pct = Float.round(hour_row.included_requests / hour_total * 100, 1)
          [%{height_pct: pct, color: "bg-base-300/30", is_pay_per_token: false}]
        else
          []
        end

      # 2. Segmentos pay_per_token por model alias (colores)
      ppt_segments =
        all_models
        |> Enum.with_index()
        |> Enum.map(fn {model_info, idx} ->
          model_name = model_info.model

          model_data =
            Enum.find(
              hour_row.models,
              %{requests: 0, cost_usd: Decimal.new(0)},
              &(&1.model == model_name and &1.billing_mode == "pay_per_token")
            )

          if model_data.requests > 0 do
            pct = Float.round(model_data.requests / hour_total * 100, 1)

            %{
              height_pct: pct,
              color: model_color(idx),
              is_pay_per_token: true
            }
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      included_segment ++ ppt_segments
    end
  end

  def legend_data(stacked_rows, hovered_hour) do
    all_models = top_models_from_stacked(stacked_rows)

    source_models =
      if hovered_hour do
        hour_row = Enum.find(stacked_rows, &(&1.hour == hovered_hour))
        if hour_row, do: hour_row.models, else: []
      else
        stacked_rows
        |> Enum.flat_map(& &1.models)
        |> Enum.group_by(& &1.model)
        |> Enum.map(fn {model, entries} ->
          requests = Enum.reduce(entries, 0, &(&1.requests + &2))

          cost =
            Enum.reduce(entries, Decimal.new(0), fn e, acc -> Decimal.add(acc, e.cost_usd) end)

          %{model: model, requests: requests, cost_usd: cost}
        end)
      end

    legend_entries =
      all_models
      |> Enum.with_index()
      |> Enum.map(fn {model_info, idx} ->
        model_name = model_info.model

        data =
          Enum.find(
            source_models,
            %{requests: 0, cost_usd: Decimal.new(0)},
            &(&1.model == model_name)
          )

        %{
          model: model_name,
          requests: data.requests,
          cost_usd: data.cost_usd,
          color: model_color(idx)
        }
      end)
      |> Enum.filter(&(&1.requests > 0))
      |> Enum.sort_by(& &1.requests, :desc)

    total_requests = Enum.reduce(legend_entries, 0, &(&1.requests + &2))

    total_cost =
      legend_entries
      |> Enum.reduce(Decimal.new(0), fn e, acc -> Decimal.add(acc, e.cost_usd) end)

    %{
      entries: legend_entries,
      total_requests: total_requests,
      total_cost_usd: total_cost,
      hovered_hour: hovered_hour
    }
  end

  def hour_bar_height(count, max) when max > 0, do: max(round(count / max * 100), 4)
  def hour_bar_height(_count, _max), do: 0

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  def accent_bg("primary"), do: "bg-primary/10"
  def accent_bg("success"), do: "bg-success/10"
  def accent_bg("accent"), do: "bg-accent/10"
  def accent_bg(_), do: "bg-base-300"

  def accent_text("primary"), do: "text-primary"
  def accent_text("success"), do: "text-success"
  def accent_text("accent"), do: "text-accent"
  def accent_text(_), do: "text-base-content/60"

  @doc "Sort a breakdown list by field and direction."
  def sort_rows([], _field, _direction), do: []

  def sort_rows(rows, field, direction) do
    Enum.sort_by(rows, &Map.get(&1, field), fn a, b ->
      case {a, b} do
        {nil, nil} ->
          true

        {nil, _} ->
          direction == :asc

        {_, nil} ->
          direction == :desc

        {a, b} ->
          if direction == :asc do
            compare_values(a, b) != :gt
          else
            compare_values(a, b) != :lt
          end
      end
    end)
  end

  defp compare_values(a, b) when is_struct(a, Decimal) and is_struct(b, Decimal),
    do: Decimal.compare(a, b)

  defp compare_values(a, b) when is_binary(a) and is_binary(b), do: if(a <= b, do: :lt, else: :gt)
  defp compare_values(a, b), do: if(a <= b, do: :lt, else: :gt)

  @doc "Sort indicator for table headers."
  def sort_icon(assigns) do
    ~H"""
    <span class="inline-block w-3 text-center">
      <%= if @current == @field do %>
        <%= if @direction == :asc do %>
          ▲
        <% else %>
          ▼
        <% end %>
      <% end %>
    </span>
    """
  end
end
