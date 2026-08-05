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
      |> assign(:sort_field, :requests)
      |> assign(:sort_direction, :desc)
      |> assign(:hour_distribution, [])
      |> assign(:busiest_hours, [])
      |> assign(:busiest_minutes, [])
      |> assign(:peak_concurrency, nil)
      |> assign(:hourly_series, [])
      |> assign(:user_ranking, [])

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
      |> load_data(socket.assigns.current_user)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(today 7d 30d 90d) do
    user = socket.assigns[:current_user]
    {:noreply, socket |> assign(:period, period) |> load_data(user)}
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
     socket |> assign(:sort_field, sort_field) |> assign(:sort_direction, sort_direction)}
  end

  defp toggle_direction(:asc), do: :desc
  defp toggle_direction(:desc), do: :asc

  ## Data loading ---------------------------------------------------------

  defp load_data(socket, user) do
    period = socket.assigns[:period]
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    %{from: from, to: to} = Periods.period_bounds(period, timezone)
    opts = [from: from, to: to, timezone: timezone]
    action = socket.assigns.live_action

    socket
    |> load_summary(user, opts)
    |> load_breakdowns(action, user, opts)
    |> assign(:loading, false)
  end

  defp load_summary(socket, user, opts) do
    summary = fetch_summary(user, opts, socket.assigns)

    metrics = %{
      requests_total: summary.request_count,
      cost_usd: summary.total_cost_usd,
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
      avg_tps: Map.get(summary, :avg_tps)
    }

    assign(socket, :metrics, metrics)
  end

  defp fetch_summary(%{global_role: "admin"}, opts, assigns) do
    opts
    |> apply_stats_filters(assigns)
    |> Logs.cost_summary()
  end

  defp fetch_summary(%{global_role: "user"} = user, opts, _assigns) do
    memberships = Accounts.list_team_members_for_user(user.id)
    member_ids = Enum.map(memberships, & &1.id)

    opts
    |> Map.new()
    |> Map.put(:team_member_ids, member_ids)
    |> Logs.cost_summary()
  end

  defp fetch_summary(_user, _opts, _assigns), do: empty_summary()

  # Build a filter map from the active stats page filter so cost_summary
  # returns data scoped to the selected model / team / service.
  defp apply_stats_filters(opts, assigns) do
    base = Map.new(opts)

    cond do
      assigns[:model_filter] ->
        Map.put(base, :model_alias_id, assigns.model_filter)

      assigns[:team_filter] ->
        Map.put(base, :team_id, assigns.team_filter)

      assigns[:service_filter] ->
        Map.put(base, :team_member_id, assigns.service_filter)

      true ->
        base
    end
  end

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
    |> assign(:user_ranking, load_user_ranking(user, opts))
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
    |> assign(
      :breakdown_model,
      sort_rows(
        base.assigns.breakdown_model,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
    |> assign(
      :breakdown_provider,
      sort_rows(
        base.assigns.breakdown_provider,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
    |> assign(
      :breakdown_team,
      sort_rows(
        base.assigns.breakdown_team,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
    |> assign(
      :breakdown_member,
      sort_rows(
        base.assigns.breakdown_member,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
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
    |> assign(
      :breakdown_team,
      sort_rows(
        base.assigns.breakdown_team,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
    |> assign(
      :breakdown_member,
      sort_rows(
        base.assigns.breakdown_member,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
    |> assign(
      :breakdown_model,
      sort_rows(
        base.assigns.breakdown_model,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
  end

  defp load_breakdowns(socket, :services, user, opts) do
    service_id = socket.assigns[:service_filter]

    base =
      socket
      |> assign(:breakdown_service, load_service_breakdown(user, opts))

    # Services are admin-only; no scoping needed beyond admin check.
    # Services are virtual team members — filter by team_member_id, not team_id.
    if service_id && user.global_role == "admin" do
      base
      |> assign(
        :breakdown_model,
        Rollup.breakdown_by_model(nil, Keyword.put(opts, :team_member_id, service_id))
      )
    else
      base
      |> assign(:breakdown_model, [])
    end
    |> assign(
      :breakdown_service,
      sort_rows(
        base.assigns.breakdown_service,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
    |> assign(
      :breakdown_model,
      sort_rows(
        base.assigns.breakdown_model,
        socket.assigns.sort_field,
        socket.assigns.sort_direction
      )
    )
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

  defp load_team_breakdown(%{global_role: "admin"}, opts) do
    Rollup.breakdown_by_team(opts)
  end

  defp load_team_breakdown(_, _), do: []

  defp load_service_breakdown(%{global_role: "admin"}, opts) do
    Rollup.breakdown_by_service(opts)
  end

  defp load_service_breakdown(_, _), do: []

  # Ranking de proveedores: métrica de infraestructura, solo admin, siempre org-wide.
  defp load_provider_ranking(%{global_role: "admin"}, opts),
    do: Rollup.provider_ranking(nil, opts)

  defp load_provider_ranking(_user, _opts), do: []

  # Ranking de modelos: mismo criterio que proveedores, solo admin.
  defp load_model_ranking(%{global_role: "admin"}, opts),
    do: Rollup.model_ranking(nil, opts)

  defp load_model_ranking(_user, _opts), do: []

  # Ranking de usuarios: consumo por usuario, solo admin.
  defp load_user_ranking(%{global_role: "admin"}, opts),
    do: Rollup.user_ranking(nil, opts)

  defp load_user_ranking(_user, _opts), do: []

  # Concurrencia pico: métrica de infraestructura, solo admin, siempre org-wide.
  defp load_peak_concurrency(%{global_role: "admin"}, opts),
    do: Rollup.peak_concurrency(nil, opts)

  defp load_peak_concurrency(_user, _opts), do: nil

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
