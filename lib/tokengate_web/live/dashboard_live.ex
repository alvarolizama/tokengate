defmodule TokengateWeb.DashboardLive do
  @moduledoc """
  Real-time metrics dashboard with role-scoped data, plus a personal
  overview: API usage info, the user's own API keys (replace/revoke),
  their teams with live budget spend.

  Scope is determined by the signed-in user's memberships:

    * **admin** (`global_role == "admin"`) — org-wide in-memory counters
      (`Tokengate.Metrics.Collector.snapshot/0`) plus a 24h durable hourly
      cost series (`Tokengate.Metrics.Rollup.hourly_series(nil, 24)`).
    * **manager** (any membership with `team_role == "manager"`) — aggregates
      metrics across every team where they are a manager, using the durable
      rollups + `Tokengate.Logs.cost_summary_for_team/2` per team.
    * **user** (no manager memberships) — only their own consumption across
      all their team_member ids via `Tokengate.Logs.cost_summary_for_members/2`.

  Real-time updates come from `Phoenix.PubSub` on the `"metrics:updated"`
  topic (broadcast by `Tokengate.Metrics.Collector.record_request/1`).
  On `{:metrics_updated, _}` the LiveView re-fetches its snapshot.

  All UI strings are in Spanish (the app's UI language).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Logs
  alias Tokengate.Metrics.Collector
  alias Tokengate.Metrics.Rollup

  @pubsub Tokengate.PubSub
  @metrics_topic "metrics:updated"
  @hours_window 24

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Dashboard · Tokengate")
      |> assign(:loading, true)
      |> assign(:metrics, empty_metrics())
      |> assign(:hourly_series, [])
      |> assign(:scope_label, scope_label_for(user))
      |> assign(:new_token, nil)
      |> assign(:new_token_team, nil)
      |> load_personal_data(user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @metrics_topic)
    end

    socket = load_metrics(socket, user)

    {:ok, socket}
  end

  @impl true
  def handle_info({:metrics_updated, _lite}, socket) do
    user = socket.assigns[:current_user]
    {:noreply, load_metrics(socket, user)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events — API key management --------------------------------------------

  @impl true
  def handle_event("replace_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case Enum.find(socket.assigns[:memberships], &(&1.id == member_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "No autorizado.")}

      member ->
        case Accounts.replace_api_key(member) do
          {:ok, _api_key, new_token} ->
            {:noreply,
             socket
             |> assign(:new_token, new_token)
             |> assign(:new_token_team, member.team.name)
             |> load_personal_data(user)
             |> put_flash(:info, "Clave reemplazada correctamente.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "No se pudo reemplazar la clave.")}
        end
    end
  end

  def handle_event("revoke_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case Enum.find(socket.assigns[:memberships], &(&1.id == member_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "No autorizado.")}

      member ->
        case member.api_key do
          nil ->
            {:noreply, put_flash(socket, :error, "Esta membresía no tiene clave.")}

          api_key ->
            case Accounts.revoke_api_key(api_key) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> load_personal_data(user)
                 |> put_flash(:info, "Clave revocada.")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
            end
        end
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  ## Data loading ---------------------------------------------------------

  defp load_personal_data(socket, user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    socket
    |> assign(:memberships, memberships)
    |> assign(:team_budgets, build_team_budgets(memberships))
  end

  # Build a list of %{team: team, daily_limit: Decimal, monthly_limit: Decimal,
  # daily_spend: Decimal, monthly_spend: Decimal, members_count: integer}
  # for each distinct team the user belongs to.
  defp build_team_budgets(memberships) do
    memberships
    |> Enum.uniq_by(& &1.team_id)
    |> Enum.map(fn membership ->
      team = membership.team
      limits = Accounts.effective_limits(membership)
      spend = Budgets.spend(membership.id)

      %{
        team: team,
        daily_limit: limits.daily_budget_usd,
        monthly_limit: limits.monthly_budget_usd,
        daily_spend: spend.daily_usd,
        monthly_spend: spend.monthly_usd
      }
    end)
  end

  # Admins: org-wide in-memory snapshot + org-wide hourly series.
  defp load_metrics(socket, %{global_role: "admin"} = _user) do
    snap = Collector.snapshot()
    hourly = Rollup.hourly_series(nil, @hours_window)

    metrics = %{
      requests_total: snap.requests_total,
      errors_total: snap.errors_total,
      error_rate: snap.error_rate,
      cost_usd: snap.cost_usd,
      savings_usd: snap.savings_usd,
      prompt_tokens: snap.prompt_tokens,
      completion_tokens: snap.completion_tokens,
      latency_avg_ms: snap.latency.avg_ms,
      latency_p95_ms: snap.latency.p95_ms
    }

    socket
    |> assign(:metrics, metrics)
    |> assign(:hourly_series, hourly)
    |> assign(:loading, false)
  end

  # Non-admins: decide manager vs user scope based on team memberships.
  defp load_metrics(socket, %{global_role: "user"} = user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(fn tm -> tm.team_role == "manager" end)
      |> Enum.map(fn tm -> tm.team_id end)
      |> Enum.uniq()

    member_ids = Enum.map(memberships, & &1.id)

    # Managers see their managed teams' metrics; regular users see their own.
    {metrics, hourly} =
      if manager_team_ids != [] do
        {aggregate_team_metrics(manager_team_ids), merge_hourly_series(manager_team_ids)}
      else
        {load_user_metrics(member_ids), user_hourly_series(member_ids)}
      end

    socket
    |> assign(:metrics, metrics)
    |> assign(:hourly_series, hourly)
    |> assign(:loading, false)
  end

  # Fallback (shouldn't be reached — :require_authenticated guards).
  defp load_metrics(socket, _user) do
    socket
    |> assign(:loading, false)
  end

  # Sum metrics across a list of team_ids. Uses cost_summary_for_team (which
  # returns request_count + tokens + costs) per team.
  defp aggregate_team_metrics(team_ids) do
    from = hours_ago_dt(@hours_window)

    Enum.reduce(team_ids, empty_metrics(), fn team_id, acc ->
      summary = Logs.cost_summary_for_team(team_id, %{from: from})

      %{
        acc
        | requests_total: acc.requests_total + summary.request_count,
          cost_usd: Decimal.add(acc.cost_usd, summary.total_cost_usd),
          savings_usd: Decimal.add(acc.savings_usd, summary.total_savings_usd),
          prompt_tokens: acc.prompt_tokens + summary.total_prompt_tokens,
          completion_tokens: acc.completion_tokens + summary.total_completion_tokens
      }
    end)
  end

  # User scope: own consumption via their team_member ids.
  defp load_user_metrics(team_member_ids) do
    from = hours_ago_dt(@hours_window)
    summary = Logs.cost_summary_for_members(team_member_ids, %{from: from})

    %{
      requests_total: summary.request_count,
      errors_total: 0,
      error_rate: 0.0,
      cost_usd: summary.total_cost_usd,
      savings_usd: summary.total_savings_usd,
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
      latency_avg_ms: 0.0,
      latency_p95_ms: 0
    }
  end

  # For the user scope we don't have a per-member hourly_series helper in
  # Rollup, so we build a simple single-bucket summary from the totals.
  # The chart will show one bar representing the 24h window.
  defp user_hourly_series([]), do: []

  defp user_hourly_series(team_member_ids) do
    from = hours_ago_dt(@hours_window)
    summary = Logs.cost_summary_for_members(team_member_ids, %{from: from})

    [
      %{
        hour: hours_ago_dt(@hours_window),
        request_count: summary.request_count,
        cost_usd: summary.total_cost_usd,
        savings_usd: summary.total_savings_usd
      }
    ]
  end

  # Merge the per-team hourly_series into one combined, hour-bucketed list
  # for the SVG chart.
  defp merge_hourly_series(team_ids) do
    team_ids
    |> Enum.flat_map(fn team_id -> Rollup.hourly_series(team_id, @hours_window) end)
    |> Enum.group_by(fn row -> DateTime.truncate(row.hour, :second) end)
    |> Enum.map(fn {hour, rows} ->
      %{
        hour: hour,
        request_count: Enum.sum(Enum.map(rows, & &1.request_count)),
        cost_usd:
          rows
          |> Enum.map(& &1.cost_usd)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
        savings_usd:
          rows
          |> Enum.map(& &1.savings_usd)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      }
    end)
    |> Enum.sort_by(& &1.hour, DateTime)
  end

  defp empty_metrics do
    %{
      requests_total: 0,
      errors_total: 0,
      error_rate: 0.0,
      cost_usd: Decimal.new(0),
      savings_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      latency_avg_ms: 0.0,
      latency_p95_ms: 0
    }
  end

  defp hours_ago_dt(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  defp scope_label_for(%{global_role: "admin"}), do: "Organización completa"

  defp scope_label_for(%{global_role: "user"} = user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_teams =
      memberships
      |> Enum.filter(fn tm -> tm.team_role == "manager" end)
      |> Enum.map(fn tm -> tm.team.name end)

    if manager_teams == [],
      do: "Tus consumos",
      else: "Equipos: " <> Enum.join(manager_teams, ", ")
  end

  defp scope_label_for(_), do: "—"

  ## Template helpers (rendered in the .heex template) -------------------

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

  def chart_max_cost(series) do
    series
    |> Enum.map(&Decimal.to_float(&1.cost_usd))
    |> Enum.max(fn -> 0.0 end)
  end

  def accent_bg("primary"), do: "bg-primary/10"
  def accent_bg("success"), do: "bg-success/10"
  def accent_bg("error"), do: "bg-error/10"
  def accent_bg("accent"), do: "bg-accent/10"
  def accent_bg(_), do: "bg-base-300"

  def accent_text("primary"), do: "text-primary"
  def accent_text("success"), do: "text-success"
  def accent_text("error"), do: "text-error"
  def accent_text("accent"), do: "text-accent"
  def accent_text(_), do: "text-base-content"

  ## Key helpers (from ApiKeysLive) ---------------------------------------

  def masked_key(%{api_key: %{key_prefix: prefix}}) when is_binary(prefix) do
    "#{prefix}••••"
  end

  def masked_key(_), do: "Sin clave"

  def key_status_badge(%{api_key: %{status: "active"}}), do: "badge-success"
  def key_status_badge(%{api_key: %{status: "revoked"}}), do: "badge-error"
  def key_status_badge(_), do: "badge-ghost"

  def key_status_label(%{api_key: %{status: "active"}}), do: "Activa"
  def key_status_label(%{api_key: %{status: "revoked"}}), do: "Revocada"
  def key_status_label(_), do: "Sin clave"

  def format_date(datetime) do
    Calendar.strftime(datetime, "%d/%m/%Y")
  end

  ## Budget helpers -------------------------------------------------------

  def budget_pct(_spend, nil), do: nil

  def budget_pct(spend, limit) do
    spend = Decimal.to_float(spend)
    limit = Decimal.to_float(limit)
    if limit > 0, do: Float.round(spend / limit * 100, 1), else: 0.0
  end

  def budget_bar_class(pct) when is_number(pct) do
    cond do
      pct >= 90 -> "bg-error"
      pct >= 70 -> "bg-warning"
      true -> "bg-success"
    end
  end

  def budget_bar_class(_), do: "bg-base-300"
end
