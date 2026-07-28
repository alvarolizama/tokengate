defmodule TokengateWeb.DashboardLive do
  @moduledoc """
  Real-time metrics dashboard with role-scoped data, plus a personal
  overview: API usage info, the user's own API keys (replace/revoke),
  their teams with live budget spend.

  Scope is determined by the signed-in user's memberships:

    * **admin** (`global_role == "admin"`) — org-wide aggregates from
      durable Postgres rollups.
    * **manager** (any membership with `team_role == "manager"`) — aggregates
      across every team where they are a manager.
    * **user** (no manager memberships) — only their own consumption.

  All metrics are fetched from Postgres (`request_logs`) via
  `Tokengate.Logs` and `Tokengate.Metrics.Rollup` — no in-memory ETS,
  so numbers are always consistent with the durable source of truth.

  Real-time updates come from `Phoenix.PubSub` on the `"metrics:updated"`
  topic (broadcast by `Tokengate.Metrics.Collector.record_request/1`).
  On `{:metrics_updated, _}` the LiveView re-fetches its data from Postgres.

  A period selector lets the user choose: Hoy (24h), 7d, 30d, 90d.
  All UI strings are in Spanish (the app's UI language).
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup

  @pubsub Tokengate.PubSub
  @metrics_topic "metrics:updated"
  @reload_interval_ms 2_000

  # Period selector: label -> hours
  @periods %{
    "today" => 24,
    "7d" => 168,
    "30d" => 720,
    "90d" => 2160
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Dashboard · Tokengate")
      |> assign(:loading, true)
      |> assign(:reload_scheduled, false)
      |> assign(:period, "today")
      |> assign(:metrics, empty_metrics())
      |> assign(:cost_series, [])
      |> assign(:requests_series, [])
      |> assign(:savings_series, [])
      |> assign(:top_models, [])
      |> assign(:breakdown_model, [])
      |> assign(:breakdown_member, [])
      |> assign(:breakdown_team, [])
      |> assign(:active_breakdown, "model")
      |> assign(:scope_label, scope_label_for(user))
      |> assign(:scope_member_ids, Accounts.scope_member_ids(user))
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
  def handle_params(unsigned_params, _uri, socket) do
    case Map.get(unsigned_params, "period") do
      period when period in ~w(today 7d 30d 90d) ->
        {:noreply, socket |> assign(:period, period) |> load_metrics(socket.assigns.current_user)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:metrics_updated, _lite}, socket) do
    # Coalesce reloads: every proxied request broadcasts on this topic, so a
    # busy proxy would otherwise trigger a full Postgres reload per request
    # per connected dashboard. Cap at one reload per @reload_interval_ms.
    if socket.assigns[:reload_scheduled] do
      {:noreply, socket}
    else
      Process.send_after(self(), :reload_metrics, @reload_interval_ms)
      {:noreply, assign(socket, :reload_scheduled, true)}
    end
  end

  def handle_info(:reload_metrics, socket) do
    user = socket.assigns[:current_user]

    {:noreply,
     socket
     |> assign(:reload_scheduled, false)
     |> load_metrics(user)}
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

  ## Events — period selector -----------------------------------------------

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(today 7d 30d 90d) do
    user = socket.assigns[:current_user]
    {:noreply, socket |> assign(:period, period) |> load_metrics(user)}
  end

  def handle_event("set_breakdown", %{"tab" => tab}, socket)
      when tab in ~w(model member team) do
    {:noreply, assign(socket, :active_breakdown, tab)}
  end

  ## Data loading ---------------------------------------------------------

  defp load_personal_data(socket, user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    teams =
      Enum.map(memberships, fn membership ->
        limits = Accounts.effective_limits(membership)
        spend = Budgets.spend(membership.id)

        %{
          membership: membership,
          team: membership.team,
          team_role: membership.team_role,
          api_key: membership.api_key,
          daily_limit: limits.daily_budget_usd,
          monthly_limit: limits.monthly_budget_usd,
          daily_spend: spend.daily_usd,
          monthly_spend: spend.monthly_usd
        }
      end)

    socket
    |> assign(:memberships, memberships)
    |> assign(:teams, teams)
  end

  defp load_metrics(socket, user) do
    period = socket.assigns[:period] || "today"
    hours = Map.get(@periods, period, 24)
    from = hours_ago_dt(hours)
    opts = [from: from]

    socket
    |> load_summary_metrics(user, opts)
    |> load_chart_series(user, opts, period)
    |> load_breakdowns(user, opts)
    |> assign(:loading, false)
  end

  defp load_summary_metrics(socket, user, opts) do
    summary = fetch_summary(user, opts)

    metrics = %{
      requests_total: summary.request_count,
      errors_total: 0,
      error_rate: 0.0,
      cost_usd: summary.total_cost_usd,
      provider_cost_usd: summary.total_provider_cost_usd,
      estimated_cost_usd: summary.total_estimated_cost_usd,
      savings_usd: summary.total_savings_usd,
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
      avg_latency_ms: Map.get(summary, :avg_latency_ms) || 0.0,
      avg_ttft_ms: Map.get(summary, :avg_ttft_ms),
      avg_tps: Map.get(summary, :avg_tps)
    }

    assign(socket, :metrics, metrics)
  end

  # Admin: org-wide summary
  defp fetch_summary(%{global_role: "admin"}, opts) do
    Logs.cost_summary(Map.new(opts))
  end

  # Non-admin: manager or user scope
  defp fetch_summary(%{global_role: "user"} = user, opts) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(fn tm -> tm.team_role == "manager" end)
      |> Enum.map(fn tm -> tm.team_id end)
      |> Enum.uniq()

    if manager_team_ids != [] do
      aggregate_team_summaries(manager_team_ids, opts)
    else
      member_ids = Enum.map(memberships, & &1.id)
      Logs.cost_summary_for_members(member_ids, Map.new(opts))
    end
  end

  defp fetch_summary(_user, _opts) do
    empty_summary()
  end

  defp aggregate_team_summaries(team_ids, opts) do
    Enum.reduce(team_ids, empty_summary(), fn team_id, acc ->
      s = Logs.cost_summary_for_team(team_id, Map.new(opts))

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
    end)
  end

  # Chart series — granularity depends on period
  defp load_chart_series(socket, user, opts, period) do
    hours = Map.fetch!(@periods, period)
    scope = chart_scope(user)

    series =
      case period do
        "today" -> Rollup.hourly_series(scope[:team_id], hours)
        "7d" -> Rollup.hourly_series(scope[:team_id], hours)
        _ -> daily_series(scope, hours, opts)
      end

    # For manager/user scopes, merge across teams
    series =
      case scope do
        %{team_ids: ids} when is_list(ids) and ids != [] ->
          merge_series(ids, hours, period)

        %{member_ids: ids} when is_list(ids) ->
          # Single-bucket fallback for user scope
          user_hourly_series(ids, opts, hours)

        _ ->
          series
      end

    socket
    |> assign(:cost_series, to_chart_points(series, period, :cost_usd, &usd_tooltip/1))
    |> assign(
      :requests_series,
      to_chart_points(series, period, :request_count, &requests_tooltip/1)
    )
    |> assign(:savings_series, to_chart_points(series, period, :savings_usd, &usd_tooltip/1))
  end

  # Build a daily-bucketed series for 30d/90d periods (org-wide)
  defp daily_series(%{team_id: nil}, _hours, opts) do
    from = Keyword.fetch!(opts, :from)

    query =
      from(rl in Tokengate.Logs.RequestLog,
        where: rl.inserted_at >= ^from,
        group_by: fragment("date_trunc('day', ?)", rl.inserted_at),
        order_by: fragment("date_trunc('day', ?)", rl.inserted_at),
        select: %{
          hour: fragment("date_trunc('day', ?)", rl.inserted_at),
          request_count: count(rl.id),
          cost_usd: fragment("COALESCE(SUM(cost_usd), 0)"),
          savings_usd: fragment("COALESCE(SUM(savings_usd), 0)")
        }
      )

    Tokengate.Repo.all(query)
    |> Enum.map(fn row ->
      %{
        hour: to_utc_datetime(row.hour),
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        savings_usd: Decimal.new(to_string(row.savings_usd))
      }
    end)
  end

  defp daily_series(_, _, _), do: []

  defp chart_scope(%{global_role: "admin"}) do
    %{team_id: nil}
  end

  defp chart_scope(%{global_role: "user"} = user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(fn tm -> tm.team_role == "manager" end)
      |> Enum.map(fn tm -> tm.team_id end)
      |> Enum.uniq()

    if manager_team_ids != [] do
      %{team_ids: manager_team_ids}
    else
      %{member_ids: Enum.map(memberships, & &1.id)}
    end
  end

  defp chart_scope(_), do: %{team_id: nil}

  # Merge per-team hourly or daily series into one combined, bucketed list
  defp merge_series(team_ids, hours, period) do
    team_ids
    |> Enum.flat_map(fn team_id -> Rollup.hourly_series(team_id, hours) end)
    |> merge_series_buckets(period)
  end

  defp merge_series_buckets(rows, _period) do
    rows
    |> Enum.group_by(fn row -> DateTime.truncate(row.hour, :second) end)
    |> Enum.map(fn {hour, grouped} ->
      %{
        hour: hour,
        request_count: Enum.sum(Enum.map(grouped, & &1.request_count)),
        cost_usd:
          grouped
          |> Enum.map(& &1.cost_usd)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
        savings_usd:
          grouped
          |> Enum.map(& &1.savings_usd)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      }
    end)
    |> Enum.sort_by(& &1.hour, DateTime)
  end

  defp user_hourly_series([], _opts, _hours), do: []

  defp user_hourly_series(member_ids, opts, hours) do
    summary = Logs.cost_summary_for_members(member_ids, Map.new(opts))

    [
      %{
        hour: hours_ago_dt(hours),
        request_count: summary.request_count,
        cost_usd: summary.total_cost_usd,
        savings_usd: summary.total_savings_usd
      }
    ]
  end

  # Breakdowns
  defp load_breakdowns(socket, user, opts) do
    # Scoping: non-admin users only see consumption of their own scope
    # (managed teams for managers, own memberships for regular users).
    opts = Keyword.put(opts, :member_ids, socket.assigns[:scope_member_ids])
    breakdown_model = Rollup.breakdown_by_model(nil, opts)

    socket
    |> assign(:breakdown_model, breakdown_model)
    |> assign(:top_models, top_model_rows(breakdown_model))
    |> assign(:breakdown_member, Rollup.breakdown_by_member(nil, opts))
    |> assign(:breakdown_team, load_team_breakdown(user, opts))
  end

  # Top 5 models by real (paid) cost for the horizontal-bars chart
  defp top_model_rows(breakdown_model) do
    breakdown_model
    |> Enum.sort_by(fn row -> Decimal.to_float(row.provider_cost_usd) end, :desc)
    |> Enum.take(5)
    |> Enum.map(fn row ->
      cost = Decimal.to_float(row.provider_cost_usd)

      %{
        label: row.model_name,
        value: cost,
        tooltip: "$#{Float.round(cost, 6)} · #{row.request_count} req"
      }
    end)
  end

  # Normalizes a bucketed rollup row into a chart point %{label, value, tooltip}
  defp to_chart_points(series, period, field, tooltip_fn) do
    Enum.map(series, fn row ->
      value =
        case Map.fetch!(row, field) do
          %Decimal{} = d -> Decimal.to_float(d)
          n when is_number(n) -> n * 1.0
        end

      %{label: bucket_label(row.hour, period), value: value, tooltip: tooltip_fn.(value)}
    end)
  end

  defp bucket_label(hour, period) when period in ["today", "7d"] do
    Calendar.strftime(hour, "%d/%m %H:%M")
  end

  defp bucket_label(hour, _period), do: Calendar.strftime(hour, "%d/%m")

  defp usd_tooltip(value), do: "#{Float.round(value, 6)} USD"
  defp requests_tooltip(value), do: "#{trunc(value)} requests"

  # Team breakdown: only admin and manager
  defp load_team_breakdown(%{global_role: "admin"}, opts) do
    Rollup.breakdown_by_team(opts)
  end

  defp load_team_breakdown(%{global_role: "user"} = user, opts) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(fn tm -> tm.team_role == "manager" end)
      |> Enum.map(fn tm -> tm.team_id end)
      |> Enum.uniq()

    if manager_team_ids != [] do
      Rollup.breakdown_by_team(opts)
      |> Enum.filter(fn row -> row.team_id in manager_team_ids end)
    else
      []
    end
  end

  defp load_team_breakdown(_, _), do: []

  defp empty_metrics do
    %{
      requests_total: 0,
      errors_total: 0,
      error_rate: 0.0,
      cost_usd: Decimal.new(0),
      provider_cost_usd: Decimal.new(0),
      estimated_cost_usd: Decimal.new(0),
      savings_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      avg_latency_ms: 0.0,
      avg_ttft_ms: nil,
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
      avg_latency_ms: nil,
      avg_tps: nil
    }
  end

  defp hours_ago_dt(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt

  defp to_utc_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
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

  def format_latency(nil), do: "—"
  def format_latency(n) when is_number(n), do: "#{Float.round(n * 1.0, 1)} ms"

  def chart_max_value(points) do
    points
    |> Enum.map(& &1.value)
    |> Enum.max(fn -> 0.0 end)
  end

  def period_label("today"), do: "Hoy"
  def period_label("7d"), do: "7 días"
  def period_label("30d"), do: "30 días"
  def period_label("90d"), do: "90 días"
  def period_label(_), do: "Hoy"

  def period_active?(current, target), do: current == target

  def breakdown_tab_active?(current, target), do: current == target

  def chart_title(period), do: series_title("Costo", period)
  def requests_title(period), do: series_title("Requests", period)
  def savings_title(period), do: series_title("Ahorro", period)

  defp series_title(label, period) do
    base =
      case period do
        "today" -> "por hora"
        "7d" -> "por hora (7d)"
        "30d" -> "por día (30d)"
        "90d" -> "por día (90d)"
        _ -> "por hora"
      end

    "#{label} #{base}"
  end

  def has_breakdown_data?(breakdown), do: breakdown != []

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

  ## Chart components ------------------------------------------------------

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: "hero-chart-bar"
  attr :series, :list, required: true
  attr :bar_class, :string, default: "fill-primary/70 hover:fill-primary"
  attr :empty_label, :string, default: "Sin datos para este periodo."

  def bar_chart(assigns) do
    max_value = chart_max_value(assigns.series)
    bar_count = max(length(assigns.series), 1)

    assigns =
      assigns
      |> assign(:max_value, max_value)
      |> assign(:bar_width, max(380 / bar_count - 4, 2))

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
          {@title}
        </h2>

        <%= if @series == [] or @max_value == 0.0 do %>
          <div class="h-40 flex items-center justify-center text-base-content/40 text-sm">
            {@empty_label}
          </div>
        <% else %>
          <svg viewBox="0 0 400 150" class="w-full h-40 mt-4" preserveAspectRatio="none">
            <%= for {row, i} <- Enum.with_index(@series) do %>
              <% height = if @max_value > 0, do: max(row.value / @max_value * 120, 1), else: 1 %>
              <% x = 10 + i * (@bar_width + 4) %>
              <% y = 140 - height %>
              <rect
                x={x}
                y={y}
                width={@bar_width}
                height={height}
                rx="2"
                class={[@bar_class, "transition-colors"]}
              >
                <title>
                  {row.label} — {row.tooltip}
                </title>
              </rect>
            <% end %>
            <line x1="10" y1="140" x2="390" y2="140" class="stroke-base-300" stroke-width="1" />
          </svg>
        <% end %>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: "hero-chart-bar-square"
  attr :rows, :list, required: true
  attr :empty_label, :string, default: "Sin datos para este periodo."

  def hbars_chart(assigns) do
    assigns = assign(assigns, :max_value, chart_max_value(assigns.rows))

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
          {@title}
        </h2>

        <%= if @rows == [] or @max_value == 0.0 do %>
          <div class="h-40 flex items-center justify-center text-base-content/40 text-sm">
            {@empty_label}
          </div>
        <% else %>
          <div class="mt-4 space-y-3">
            <div :for={row <- @rows} class="group">
              <div class="flex items-center justify-between text-xs mb-1 gap-2">
                <span class="font-medium truncate" title={row.label}>{row.label}</span>
                <span class="font-mono text-base-content/60 whitespace-nowrap">{row.tooltip}</span>
              </div>
              <div class="h-2.5 rounded-full bg-base-200 overflow-hidden">
                <div
                  class="h-full rounded-full bg-primary/70 group-hover:bg-primary transition-all"
                  style={"width: #{Float.round(max(row.value / @max_value * 100, 2.0), 1)}%"}
                />
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
