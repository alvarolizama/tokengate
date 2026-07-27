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

  import Ecto.Query, only: [from: 2]

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
      |> assign(:loading, true)
      |> assign(:metrics, empty_metrics())
      |> assign(:breakdown_model, [])
      |> assign(:breakdown_member, [])
      |> assign(:breakdown_team, [])
      |> assign(:breakdown_provider, [])
      |> assign(:hourly_series, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = parse_period(params["period"])
    model_filter = params["model_id"]
    team_filter = params["team_id"]

    socket =
      socket
      |> assign(:period, period)
      |> assign(:model_filter, model_filter)
      |> assign(:team_filter, team_filter)
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

    manager_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    if manager_team_ids != [] do
      Enum.reduce(manager_team_ids, empty_summary(), fn team_id, acc ->
        s = Logs.cost_summary_for_team(team_id, Map.new(opts))
        merge_summaries(acc, s)
      end)
    else
      member_ids = Enum.map(memberships, & &1.id)
      Logs.cost_summary_for_members(member_ids, Map.new(opts))
    end
  end

  defp fetch_summary(_user, _opts), do: empty_summary()

  defp load_breakdowns(socket, :index, user, opts) do
    scope = scope_for(user)

    socket
    |> assign(:breakdown_model, Rollup.breakdown_by_model(scope[:team_id], opts))
    |> assign(:breakdown_member, load_member_breakdown(scope, opts))
    |> assign(:breakdown_team, load_team_breakdown(user, opts))
  end

  defp load_breakdowns(socket, :models, user, opts) do
    model_id = socket.assigns[:model_filter]
    scope = scope_for(user)

    base =
      socket
      |> assign(:breakdown_model, Rollup.breakdown_by_model(scope[:team_id], opts))

    if model_id do
      base
      |> assign(:breakdown_provider, Rollup.breakdown_by_provider_for_model(model_id, opts))
      |> assign(:breakdown_team, Rollup.breakdown_by_team_for_model(model_id, opts))
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

    if team_id do
      base
      |> assign(:breakdown_member, Rollup.breakdown_by_member(team_id, opts))
      |> assign(:breakdown_model, Rollup.breakdown_by_model(team_id, opts))
    else
      base
      |> assign(:breakdown_member, [])
      |> assign(:breakdown_model, [])
    end
  end

  ## Scoping helpers ------------------------------------------------------

  defp scope_for(%{global_role: "admin"}) do
    %{team_id: nil, manager_team_ids: nil, member_ids: nil}
  end

  defp scope_for(%{global_role: "user"} = user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    if manager_team_ids != [] do
      %{team_id: nil, manager_team_ids: manager_team_ids, member_ids: nil}
    else
      %{team_id: nil, manager_team_ids: nil, member_ids: Enum.map(memberships, & &1.id)}
    end
  end

  defp scope_for(_), do: %{team_id: nil, manager_team_ids: nil, member_ids: nil}

  defp scoped_teams(%{global_role: "admin"}) do
    Accounts.list_teams()
  end

  defp scoped_teams(%{global_role: "user"} = user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    if manager_team_ids != [] do
      from(t in Tokengate.Accounts.Team, where: t.id in ^manager_team_ids)
      |> Tokengate.Repo.all()
    else
      []
    end
  end

  defp scoped_teams(_), do: []

  defp load_member_breakdown(%{manager_team_ids: ids}, _opts) when is_list(ids) and ids != [] do
    Enum.flat_map(ids, fn team_id -> Rollup.breakdown_by_member(team_id, []) end)
  end

  defp load_member_breakdown(%{member_ids: ids}, opts) when is_list(ids) and ids != [] do
    Rollup.breakdown_by_member(nil, opts)
    |> Enum.filter(fn row -> row.team_member_id in ids end)
  end

  defp load_member_breakdown(%{team_id: team_id}, opts) do
    Rollup.breakdown_by_member(team_id, opts)
  end

  defp load_team_breakdown(%{global_role: "admin"}, opts) do
    Rollup.breakdown_by_team(opts)
  end

  defp load_team_breakdown(%{global_role: "user"} = user, opts) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    if manager_team_ids != [] do
      Rollup.breakdown_by_team(opts)
      |> Enum.filter(fn row -> row.team_id in manager_team_ids end)
    else
      []
    end
  end

  defp load_team_breakdown(_, _), do: []

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

  defp merge_summaries(acc, s) do
    %{
      acc
      | request_count: acc.request_count + s.request_count,
        total_cost_usd: Decimal.add(acc.total_cost_usd, s.total_cost_usd),
        total_provider_cost_usd:
          Decimal.add(acc.total_provider_cost_usd, s.total_provider_cost_usd),
        total_savings_usd: Decimal.add(acc.total_savings_usd, s.total_savings_usd),
        total_estimated_cost_usd:
          Decimal.add(acc.total_estimated_cost_usd, s.total_estimated_cost_usd),
        total_prompt_tokens: acc.total_prompt_tokens + s.total_prompt_tokens,
        total_completion_tokens: acc.total_completion_tokens + s.total_completion_tokens
    }
  end

  defp scope_label_for(%{global_role: "admin"}), do: "Organización completa"

  defp scope_label_for(%{global_role: "user"} = user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_teams =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team.name)

    if manager_teams == [],
      do: "Tus consumos",
      else: "Equipos: " <> Enum.join(manager_teams, ", ")
  end

  defp scope_label_for(_), do: "—"

  ## Template helpers -----------------------------------------------------

  def format_decimal(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  def format_decimal(n) when is_number(n), do: to_string(n)
  def format_decimal(_), do: "0"

  def format_number(n) when is_integer(n), do: Integer.to_string(n)
  def format_number(n) when is_float(n), do: Float.to_string(n)
  def format_number(_), do: "0"

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

  def accent_bg("primary"), do: "bg-primary/10"
  def accent_bg("success"), do: "bg-success/10"
  def accent_bg("accent"), do: "bg-accent/10"
  def accent_bg(_), do: "bg-base-300"

  def accent_text("primary"), do: "text-primary"
  def accent_text("success"), do: "text-success"
  def accent_text("accent"), do: "text-accent"
  def accent_text(_), do: "text-base-content"
end
