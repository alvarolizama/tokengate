defmodule TokengateWeb.StatsLive do
  @moduledoc """
  Analytics dashboard with drill-down by model and team.

  Three views via `live_action`:
    * `:index`  — overview with top-N tables and KPI cards
    * `:models` — per-model breakdown + drill-down (provider, team, member)
    * `:teams`  — per-team breakdown + drill-down (members, models)

  Periods: 7d, 30d, 90d (no "today" — this is analytics, not real-time monitoring).

  Scoping by role:
    * admin   — org-wide
    * manager — only teams they manage
    * user    — only their own consumption

  CSV export available via `/dashboard/stats/export` controller.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Providers

  @periods %{"7d" => 168, "30d" => 720, "90d" => 2160}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Estadísticas · Tokengate")
      |> assign(:period, "7d")
      |> assign(:model_filter, nil)
      |> assign(:team_filter, nil)
      |> assign(:models, Providers.list_model_aliases())
      |> assign(:teams, scoped_teams(user))
      |> assign(:scope_label, scope_label_for(user))
      |> assign(:scope_member_ids, Accounts.scope_member_ids(user))
      |> assign(:loading, true)
      |> assign(:metrics, empty_metrics())
      |> assign(:breakdown_model, [])
      |> assign(:breakdown_member, [])
      |> assign(:breakdown_team, [])
      |> assign(:breakdown_provider, [])
      |> assign(:top_errors, [])
      |> assign(:provider_ranking, [])
      |> assign(:model_ranking, [])
      |> assign(:member, nil)
      |> assign(:member_models, [])
      |> assign(:member_id, nil)
      |> assign(:hour_distribution, [])
      |> assign(:busiest_hours, [])
      |> assign(:busiest_minutes, [])
      |> assign(:peak_concurrency, nil)
      |> assign(:hourly_series, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = parse_period(params["period"])
    model_filter = params["model_id"]
    team_filter = params["team_id"]
    member_id = params["member_id"]

    socket =
      socket
      |> assign(:period, period)
      |> assign(:model_filter, model_filter)
      |> assign(:team_filter, team_filter)
      |> assign(:member_id, member_id)
      |> load_data(socket.assigns.current_user)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(7d 30d 90d) do
    {:noreply, push_patch(socket, to: build_path(socket, period: period))}
  end

  def handle_event("set_model_filter", %{"model_id" => model_id}, socket) do
    model_id = if model_id == "", do: nil, else: model_id
    {:noreply, push_patch(socket, to: build_path(socket, model_id: model_id))}
  end

  def handle_event("set_team_filter", %{"team_id" => team_id}, socket) do
    team_id = if team_id == "", do: nil, else: team_id
    {:noreply, push_patch(socket, to: build_path(socket, team_id: team_id))}
  end

  def handle_event("clear_model_filter", _params, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, model_id: nil))}
  end

  def handle_event("clear_team_filter", _params, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, team_id: nil))}
  end

  ## Data loading ---------------------------------------------------------

  defp load_data(socket, user) do
    period = socket.assigns[:period]
    hours = Map.fetch!(@periods, period)
    from = hours_ago_dt(hours)
    opts = [from: from]
    action = socket.assigns.live_action

    socket
    |> load_summary(user, opts)
    |> load_breakdowns(action, user, opts)
    |> assign(:loading, false)
  end

  defp load_summary(socket, user, opts) do
    summary = fetch_summary(user, opts)

    metrics = %{
      requests_total: summary.request_count,
      cost_usd: summary.total_cost_usd,
      provider_cost_usd: summary.total_provider_cost_usd,
      estimated_cost_usd: summary.total_estimated_cost_usd,
      savings_usd: summary.total_savings_usd,
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
      avg_tps: Map.get(summary, :avg_tps)
    }

    assign(socket, :metrics, metrics)
  end

  defp fetch_summary(%{global_role: "admin"}, opts) do
    Logs.cost_summary(Map.new(opts))
  end

  defp fetch_summary(%{global_role: "user"} = user, opts) do
    memberships = Accounts.list_team_members_for_user(user.id)
    member_ids = Enum.map(memberships, & &1.id)
    Logs.cost_summary_for_members(member_ids, Map.new(opts))
  end

  defp fetch_summary(_user, _opts), do: empty_summary()

  defp load_breakdowns(socket, :index, user, opts) do
    # Scoping: non-admin users only see consumption of their own scope
    # (managed teams for managers, own memberships for regular users).
    opts = Keyword.put(opts, :member_ids, socket.assigns[:scope_member_ids])

    socket
    |> assign(:breakdown_model, Rollup.breakdown_by_model(nil, opts))
    |> assign(:breakdown_member, Rollup.breakdown_by_member(nil, opts))
    |> assign(:breakdown_team, load_team_breakdown(user, opts))
    |> assign(:top_errors, Rollup.top_errors(nil, opts))
    |> assign(:provider_ranking, load_provider_ranking(user, opts))
    |> assign(:model_ranking, load_model_ranking(user, opts))
    |> assign(:hour_distribution, Rollup.usage_by_hour_of_day(nil, opts))
    |> assign(:busiest_hours, Rollup.busiest_hours(nil, opts))
    |> assign(:busiest_minutes, Rollup.busiest_minutes(nil, opts))
    |> assign(:peak_concurrency, load_peak_concurrency(user, opts))
  end

  defp load_breakdowns(socket, :models, user, opts) do
    model_id = socket.assigns[:model_filter]
    opts = Keyword.put(opts, :member_ids, socket.assigns[:scope_member_ids])

    base =
      socket
      |> assign(:breakdown_model, Rollup.breakdown_by_model(nil, opts))

    if model_id do
      base
      |> assign(:breakdown_provider, Rollup.breakdown_by_provider_for_model(model_id, opts))
      |> assign(:breakdown_team, load_team_breakdown_for_model(user, model_id, opts))
      |> assign(:breakdown_member, Rollup.breakdown_by_member_for_model(model_id, opts))
    else
      base
      |> assign(:breakdown_provider, [])
      |> assign(:breakdown_team, [])
      |> assign(:breakdown_member, [])
    end
  end

  defp load_breakdowns(socket, :teams, user, opts) do
    team_id = socket.assigns[:team_filter]

    base =
      socket
      |> assign(:breakdown_team, load_team_breakdown(user, opts))

    # Fail-closed: a crafted ?team_id= for a team the user doesn't manage
    # shows empty drill-down tables instead of other teams' data.
    if team_id && team_drilldown_allowed?(user, team_id) do
      base
      |> assign(:breakdown_member, Rollup.breakdown_by_member(team_id, opts))
      |> assign(:breakdown_model, Rollup.breakdown_by_model(team_id, opts))
    else
      base
      |> assign(:breakdown_member, [])
      |> assign(:breakdown_model, [])
    end
  end

  defp load_breakdowns(socket, :member, user, opts) do
    member_id = socket.assigns[:member_id]

    # Load the team member with associations
    member = Accounts.get_team_member!(member_id, :with_assoc)

    # Scope check: non-admin users can only see members of teams they manage
    allowed? = user.global_role == "admin" or member_id in Accounts.scope_member_ids(user)

    if allowed? do
      member_models = Rollup.breakdown_by_model_for_member(member_id, opts)

      socket
      |> assign(:member, member)
      |> assign(:member_models, member_models)
    else
      socket
      |> assign(:member, nil)
      |> assign(:member_models, [])
      |> put_flash(:error, "No tienes permiso para ver este miembro.")
    end
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
  defp load_team_breakdown_for_model(user, model_id, opts) do
    case Accounts.scope_team_ids(user) do
      nil ->
        Rollup.breakdown_by_team_for_model(model_id, opts)

      [] ->
        []
    end
  end

  defp scoped_teams(user) do
    case Accounts.scope_team_ids(user) do
      nil ->
        Accounts.list_teams()

      [] ->
        []
    end
  end

  defp load_team_breakdown(%{global_role: "admin"}, opts) do
    Rollup.breakdown_by_team(opts)
  end

  defp load_team_breakdown(_, _), do: []

  # Ranking de proveedores: métrica de infraestructura, solo admin, siempre org-wide.
  defp load_provider_ranking(%{global_role: "admin"}, opts),
    do: Rollup.provider_ranking(nil, opts)

  defp load_provider_ranking(_user, _opts), do: []

  # Ranking de modelos: mismo criterio que proveedores, solo admin.
  defp load_model_ranking(%{global_role: "admin"}, opts),
    do: Rollup.model_ranking(nil, opts)

  defp load_model_ranking(_user, _opts), do: []

  # Concurrencia pico: métrica de infraestructura, solo admin, siempre org-wide.
  defp load_peak_concurrency(%{global_role: "admin"}, opts),
    do: Rollup.peak_concurrency(nil, opts)

  defp load_peak_concurrency(_user, _opts), do: nil

  ## Path building --------------------------------------------------------

  defp build_path(socket, overrides) do
    period = Keyword.get(overrides, :period, socket.assigns[:period])
    model_id = Keyword.get(overrides, :model_id, socket.assigns[:model_filter])
    team_id = Keyword.get(overrides, :team_id, socket.assigns[:team_filter])

    query =
      %{"period" => period}
      |> maybe_put("model_id", model_id)
      |> maybe_put("team_id", team_id)
      |> URI.encode_query()

    case socket.assigns.live_action do
      :index -> ~p"/dashboard/stats?#{query}"
      :models -> ~p"/dashboard/stats/models?#{query}"
      :teams -> ~p"/dashboard/stats/teams?#{query}"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  ## Helpers --------------------------------------------------------------

  defp parse_period(nil), do: "7d"
  defp parse_period(period) when period in ~w(7d 30d 90d), do: period
  defp parse_period(_), do: "7d"

  defp hours_ago_dt(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  defp empty_metrics do
    %{
      requests_total: 0,
      cost_usd: Decimal.new(0),
      provider_cost_usd: Decimal.new(0),
      estimated_cost_usd: Decimal.new(0),
      savings_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      avg_tps: nil
    }
  end

  defp empty_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_provider_cost_usd: Decimal.new(0),
      total_savings_usd: Decimal.new(0),
      total_estimated_cost_usd: Decimal.new(0),
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

  def tier_badge_class("S"), do: "badge-success"
  def tier_badge_class("A"), do: "badge-info"
  def tier_badge_class("B"), do: "badge-warning"
  def tier_badge_class("C"), do: "badge-warning badge-outline"
  def tier_badge_class("D"), do: "badge-error"
  def tier_badge_class(_), do: "badge-ghost"

  def hour_label(hour) when hour in 0..23, do: "#{pad2(hour)}:00"

  def error_class_label(status) when status >= 400 and status < 500, do: "4xx cliente"
  def error_class_label(status) when status >= 500, do: "5xx servidor"
  def error_class_label(_), do: "—"

  def error_class_badge(status) when status >= 400 and status < 500, do: "badge-warning"
  def error_class_badge(status) when status >= 500, do: "badge-error"
  def error_class_badge(_), do: "badge-ghost"

  def format_bucket(nil), do: "—"
  def format_bucket(%DateTime{} = dt), do: Calendar.strftime(dt, "%d/%m %H:%M")

  def hour_distribution_max(rows) do
    rows |> Enum.map(& &1.request_count) |> Enum.max(fn -> 0 end)
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
  def accent_text(_), do: "text-base-content"
end
