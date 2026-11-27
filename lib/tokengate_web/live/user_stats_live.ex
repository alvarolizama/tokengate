defmodule TokengateWeb.UserStatsLive do
  @moduledoc """
  Admin-only consolidated stats page for a **user**, aggregating every
  group membership the user holds.

  Shows aggregated KPI cards (requests, cost, tokens, top models, status
  breakdown, last request) for the canonical period (`?period=`, default
  `"week"` via `Tokengate.Periods`), a per-user **FinOps** section — unit
  economics (`$/req`, `$/1M tok`, Out/In, prompt-cache hit rate), waste
  (`Error waste`, `Thinking tax`), cache savings (`Local cache ($0)`,
  prompt tokens saved), top-up spend and the `$/day` burn with its 30-day
  projection — a spend/volume trend (hourly for the single-day windows,
  daily for `week`/`30d`) and a paginated stream of the user's recent logs
  across all memberships. Data loads asynchronously via `start_async/3`;
  real-time updates arrive via `logs:new` PubSub.

  Path: `/stats/users/:user_id`

  Presentation is NOT duplicated here: money, token, latency, status,
  filter and log-matching helpers all come from
  `TokengateWeb.ServiceStatsBody` / `TokengateWeb.StatsHelpers`, the same
  ones the supervised-service detail renders with, so the two surfaces
  cannot drift apart.

  Admin-only by router; defense-in-depth `require_admin_hook/1` rejects
  event traffic from non-admins (a malicious client could otherwise
  fire events directly over the WebSocket).
  """

  use TokengateWeb, :live_view
  require Logger

  import TokengateWeb.KpiHelpers, only: [kpi_card: 1]

  # Shared presentation with the service detail: ONE money/tokens/latency/
  # status/formatter set and ONE filter-matching rule for both surfaces.
  import TokengateWeb.ServiceStatsBody,
    only: [
      default_filters: 0,
      default_summary: 0,
      drop_empty_filters: 1,
      fmt_ms: 1,
      fmt_money: 1,
      fmt_tps: 1,
      format_cost: 1,
      last_request_label: 2,
      log_matches_filters?: 4,
      model_display: 2,
      parse_date_filters: 2,
      status_badge: 1
    ]

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.FinopsCharts

  @page_size 50
  @summary_refresh_interval_ms 2_000

  @impl true
  def mount(%{"user_id" => user_id} = params, _session, socket) do
    case fetch_user(user_id) do
      nil ->
        # A forged/non-UUID/stale id must not raise `CastError`/`NoResultsError`
        # inside mount (that kills the LiveView before it renders anything).
        {:ok,
         socket
         |> put_flash(:error, gettext("That user does not exist."))
         |> push_navigate(to: ~p"/stats/users")}

      user ->
        memberships = Accounts.list_group_members_for_user(user.id)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
        end

        socket =
          socket
          |> assign(:page_title, gettext("Stats") <> " · #{user.email} · Tokengate")
          |> assign(:user, user)
          |> assign(:memberships, memberships)
          |> assign(:period, Periods.normalize_period(params["period"]))
          |> assign(:loaded_period, nil)
          |> assign(:timezone, socket.assigns[:timezone] || "Etc/UTC")
          |> assign(:is_admin, socket.assigns[:current_user].global_role == "admin")
          |> assign(:filters, default_filters())
          |> assign(:form, to_form(default_filters(), as: :filter))
          |> assign(:cursor, nil)
          |> assign(:has_more, false)
          # El stream no es enumerable: `.table` necesita el flag explícito para
          # el empty-state (se recalcula en cada `handle_async(:user_logs, ...)`).
          |> assign(:logs_empty?, true)
          |> assign(:page_size, @page_size)
          |> assign(:summary, initial_summary())
          |> assign(:burn, empty_burn())
          |> assign(:series, [])
          |> assign(:trend_metric, "cost")
          |> assign(:user_breakdowns, %{agents: [], providers: []})
          |> assign(:summary_loading, true)
          |> assign(:logs_loading, true)
          |> assign(:stats_loading, true)
          |> assign(:summary_error, false)
          |> assign(:logs_error, false)
          |> assign(:load_error, false)
          |> assign(:summary_refresh_scheduled, false)
          |> stream(:logs, [], reset: true)
          |> require_admin_hook()

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{user: _user}} = socket) do
    period = Periods.normalize_period(params["period"])

    socket =
      if socket.assigns.loaded_period != period do
        initial_logs? = is_nil(socket.assigns.loaded_period)

        socket
        |> assign(:period, period)
        |> assign(:loaded_period, period)
        |> start_summary_load()
        |> then(fn s ->
          if initial_logs?, do: start_logs_load(s, :reset), else: s
        end)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # `user_id` comes from the URL: cast it before it reaches Ecto, and read with
  # the non-bang getter.
  defp fetch_user(user_id) when is_binary(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> Accounts.get_user(uuid)
      :error -> nil
    end
  end

  defp fetch_user(_user_id), do: nil

  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, gettext("Not authorized."))}
      end
    end)
  end

  ## Real-time -------------------------------------------------------------

  @impl true
  def handle_info({:new_log, log}, socket) do
    # Identidad durable: el log pertenece al usuario por `user_id`, no por
    # la membresía — un log post-rotación (member nil) también es suyo.
    if log.user_id == socket.assigns.user.id do
      timezone = socket.assigns.timezone
      filters = socket.assigns.filters

      if log_matches_filters?(log, filters, timezone, nil) do
        socket =
          socket
          |> stream_insert(:logs, log, at: 0, limit: @page_size)
          |> assign(:logs_empty?, false)

        # Coalesce summary reloads: at most one user_stats recompute per
        # interval per connected LiveView, regardless of broadcast rate.
        # Without this, every proxied request triggers Postgres aggregate
        # queries in every admin watching this page (PubSub storm).
        socket =
          if socket.assigns[:summary_refresh_scheduled] do
            socket
          else
            Process.send_after(self(), :refresh_summary, @summary_refresh_interval_ms)
            assign(socket, :summary_refresh_scheduled, true)
          end

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_summary, socket) do
    {:noreply,
     socket
     |> assign(:summary_refresh_scheduled, false)
     |> start_summary_load(false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    # A forged payload without the nested map (or with a non-map) must not
    # raise: fall back to the defaults.
    filter_params =
      case Map.get(params, "filter") do
        %{} = given -> Map.merge(default_filters(), given)
        _ -> default_filters()
      end

    socket =
      socket
      |> assign(:filters, filter_params)
      |> assign(:form, to_form(filter_params, as: :filter))
      |> assign(:cursor, nil)
      |> start_logs_load(:reset)

    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more and not socket.assigns.logs_loading do
      {:noreply, start_logs_load(socket, :more)}
    else
      {:noreply, socket}
    end
  end

  # Toggle of the trend chart: the same three metrics the FinOps page offers.
  def handle_event("user_trend_metric", %{"metric" => metric}, socket)
      when metric in ~w(cost requests cpr) do
    {:noreply, assign(socket, :trend_metric, metric)}
  end

  def handle_event("user_trend_metric", _params, socket), do: {:noreply, socket}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Async data loading ----------------------------------------------------

  defp start_summary_load(socket, show_loading \\ true) do
    user_id = socket.assigns.user.id
    period = socket.assigns.period
    timezone = socket.assigns.timezone

    socket
    |> assign(:summary_loading, show_loading)
    |> update_status_flags()
    |> start_async(:user_summary, fn ->
      %{from: from, to: to} = Periods.period_bounds(period, timezone)

      # Stats por USUARIO (identidad durable): sobrevive a la rotación de la
      # membresía. Wrap in shared DashboardCache ETS (5s TTL, keyed per
      # user + period + timezone) so concurrent viewers share recomputes.
      DashboardCache.fetch_or_compute({:user_stats, user_id, period, timezone}, fn ->
        Logs.user_stats(user_id, from: from, to: to)
      end)
    end)
    |> start_async(:user_breakdowns, fn ->
      %{from: from, to: to} = Periods.period_bounds(period, timezone)

      DashboardCache.fetch_or_compute({:user_stats_breakdowns, user_id, period, timezone}, fn ->
        Logs.user_breakdowns(user_id, from: from, to: to)
      end)
    end)
    |> start_async(:user_series, fn ->
      %{from: from, to: to} = Periods.period_bounds(period, timezone)

      # Rollup reads `request_metrics_hourly` and falls back to raw logs when
      # the tail bucket is not aggregated yet; the window stays bounded by the
      # period, so the trend never scans past the selected range.
      DashboardCache.fetch_or_compute({:user_stats_series, user_id, period, timezone}, fn ->
        Rollup.hourly_series_for_users([user_id], [from: from, to: to], timezone)
      end)
    end)
  end

  defp start_logs_load(socket, mode) do
    user_id = socket.assigns.user.id
    filters = socket.assigns.filters
    timezone = socket.assigns.timezone
    cursor = socket.assigns.cursor

    socket
    |> assign(:logs_loading, true)
    |> update_status_flags()
    |> start_async(:user_logs, fn ->
      # Filtered by user (durable identity): post-rotation logs show up too.
      #
      # "Desde"/"Hasta" arrive from the form as ISO dates: they are converted to
      # the UTC datetimes `Logs.list_logs/1` expects (a value that does not parse
      # is DROPPED — the filter is ignored).
      base_filters =
        filters
        |> Map.put("user_ids", [user_id])
        |> parse_date_filters(timezone)
        |> drop_empty_filters()

      query_filters =
        case mode do
          :reset ->
            Map.put(base_filters, "limit", @page_size)

          :more ->
            base_filters
            |> then(fn f -> if cursor, do: Map.put(f, "before", cursor), else: f end)
            |> Map.put("limit", @page_size)
        end

      {mode, Logs.list_logs_compact(query_filters)}
    end)
  end

  @impl true
  def handle_async(:user_summary, {:ok, summary}, socket) do
    {:noreply,
     socket
     |> assign(:summary, summary)
     |> assign(:burn, burn_rate(summary, socket.assigns.period, socket.assigns.timezone))
     |> assign(:summary_loading, false)
     |> assign(:summary_error, false)
     |> update_status_flags()}
  end

  def handle_async(:user_summary, {:exit, reason}, socket) do
    Logger.warning("user stats summary load failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:summary_loading, false)
     |> assign(:summary_error, true)
     |> update_status_flags()}
  end

  def handle_async(:user_breakdowns, {:ok, breakdowns}, socket) do
    {:noreply, assign(socket, :user_breakdowns, breakdowns)}
  end

  def handle_async(:user_breakdowns, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_async(:user_series, {:ok, hour_rows}, socket) do
    {:noreply, assign(socket, :series, trend_series(hour_rows, socket.assigns.period))}
  end

  def handle_async(:user_series, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :series, [])}
  end

  def handle_async(:user_logs, {:ok, {mode, logs}}, socket) do
    has_more = length(logs) == @page_size

    # `:reset` recalcula el empty-state desde cero; `:more` sólo lo apaga si
    # llegó alguna fila (una página vacía no vacía lo ya pintado).
    logs_empty? =
      case mode do
        :reset -> logs == []
        :more -> socket.assigns[:logs_empty?] == true and logs == []
      end

    socket =
      socket
      |> assign(:has_more, has_more)
      |> assign(:logs_empty?, logs_empty?)
      |> assign(:logs_loading, false)
      |> assign(:logs_error, false)
      |> update_status_flags()
      |> then(fn s ->
        if mode == :reset, do: stream(s, :logs, logs, reset: true), else: stream(s, :logs, logs)
      end)

    socket =
      case logs do
        [] ->
          socket

        _ ->
          oldest = List.last(logs)
          # Tuple cursor: `inserted_at` is timestamp(0), so a timestamp alone
          # repeats/skips the rows sharing the boundary second.
          assign(socket, :cursor, {oldest.inserted_at, oldest.id})
      end

    {:noreply, socket}
  end

  def handle_async(:user_logs, {:exit, reason}, socket) do
    Logger.warning("user stats logs load failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:logs_loading, false)
     |> assign(:logs_error, true)
     |> update_status_flags()}
  end

  defp update_status_flags(socket) do
    socket
    |> assign(:stats_loading, socket.assigns.summary_loading or socket.assigns.logs_loading)
    |> assign(:load_error, socket.assigns.summary_error or socket.assigns.logs_error)
  end

  ## FinOps derivations ----------------------------------------------------

  # `ServiceStatsBody.default_summary/0` is the shared shape; the detail adds
  # the per-user FinOps block, so the very first paint (before the async read
  # lands) already renders zeros instead of crashing on a missing key.
  defp initial_summary do
    default_summary()
    |> Map.put(:finops, %{
      requests: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      error_requests: 0,
      error_cost_usd: Decimal.new(0),
      think_requests: 0,
      think_cost_usd: Decimal.new(0),
      local_cache_hits: 0,
      router_decision_cost_usd: Decimal.new(0),
      prompt_tokens_saved_est: 0,
      topup_requests: 0,
      topup_cost_usd: Decimal.new(0)
    })
  end

  # Burn: the window's spend spread over its days (never less than one day —
  # "today" is a partial day, and dividing by 0.4 would invent a daily rate
  # nobody is running), projected to 30 days.
  defp burn_rate(%{total_cost_usd: cost}, period, timezone) do
    %{from: from, to: to} = Periods.period_bounds(period, timezone)
    days = max(1.0, DateTime.diff(to, from, :second) / 86_400)

    per_day = Decimal.div(cost, Decimal.new(Float.to_string(days)))

    %{
      days: days,
      per_day: per_day,
      projection_30d: Decimal.mult(per_day, Decimal.new(30))
    }
  end

  defp empty_burn, do: %{days: 1.0, per_day: Decimal.new(0), projection_30d: Decimal.new(0)}

  # Trend: `Rollup.hourly_series_for_users/3` always buckets by LOCAL hour.
  # `today`/`yesterday` chart those hours as-is; the wider windows fold them
  # into their local day (sums only — no extra query).
  defp trend_series(hour_rows, period) do
    if hourly_period?(period) do
      Enum.map(hour_rows, &trend_point(&1.hour, &1))
    else
      hour_rows
      |> Enum.group_by(&DateTime.to_date(&1.hour))
      |> Enum.sort_by(fn {day, _rows} -> day end)
      |> Enum.map(fn {day, rows} ->
        trend_point(
          day,
          Enum.reduce(rows, %{request_count: 0, cost_usd: Decimal.new(0)}, &sum_point/2)
        )
      end)
    end
  end

  defp trend_point(date, %{request_count: request_count, cost_usd: cost_usd}) do
    %{date: date, subject_type: "user", request_count: request_count, cost_usd: cost_usd}
  end

  defp sum_point(row, acc) do
    %{
      request_count: acc.request_count + row.request_count,
      cost_usd: Decimal.add(acc.cost_usd, row.cost_usd)
    }
  end

  defp hourly_period?(period), do: period in ["today", "yesterday"]

  ## Render ----------------------------------------------------------------

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
        <%!-- Header --%>
        <header class="flex flex-wrap items-center justify-between gap-4 pb-4">
          <div>
            <div class="flex items-center gap-2 text-xs text-base-content/60">
              <.link navigate={~p"/stats/users"} class="hover:underline">{gettext("Users")}</.link>
              <span>›</span>
              <span>{gettext("Detail")}</span>
            </div>
            <h1 class="text-lg font-semibold leading-8 mt-1">
              {@user.email}
            </h1>
            <p class="text-sm text-base-content/70">
              {@user.name || ""}
              <%= if @memberships != [] do %>
                · {length(@memberships)} {if length(@memberships) == 1,
                  do: gettext("membership"),
                  else: gettext("memberships")}
              <% end %>
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <span
              :if={@stats_loading}
              class="loading loading-spinner loading-sm text-primary"
              id="user-stats-loading"
              title={gettext("Updating statistics…")}
            ></span>
            <Stats.period_selector
              target={~p"/stats/users/#{@user.id}"}
              period={@period}
              id="period-selector"
            />
          </div>
        </header>

        <div
          :if={@load_error}
          id="user-stats-load-error"
          class="alert alert-warning text-sm"
          role="alert"
        >
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <span>
            {gettext("Could not load this period. The data below is from the previous period.")}
          </span>
        </div>

        <div
          class={["space-y-6 transition-opacity duration-200", @stats_loading && "opacity-60"]}
          id="user-stats-content"
        >
          <%!-- KPI cards (selected period) --%>
          <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-3">
            <.kpi_card
              id="user-kpi-requests"
              label={gettext("Requests")}
              icon="hero-squares-2x2"
              accent="primary"
            >
              {Stats.format_number(@summary.request_count)}
              <:sub>
                {gettext("%{count} in 5 min",
                  count: Stats.format_number(@summary.realtime_5min.request_count)
                )}
              </:sub>
            </.kpi_card>

            <.kpi_card
              id="user-kpi-cost"
              label={gettext("Cost")}
              icon="hero-currency-dollar"
              accent="accent"
            >
              {fmt_money(@summary.total_cost_usd)}
              <:sub>
                {gettext("%{count} reqs", count: Stats.format_number(@summary.request_count))}
                <span :if={@summary.request_count > 0} class="tabular-nums">
                  · {Stats.cost_per_request(@summary.total_cost_usd, @summary.request_count)}/req · {Stats.effective_cost_per_1m(
                    @summary.total_cost_usd,
                    @summary.total_prompt_tokens,
                    @summary.total_completion_tokens
                  )}/1M
                </span>
              </:sub>
            </.kpi_card>

            <.kpi_card
              id="user-kpi-input"
              label={gettext("Input tokens")}
              icon="hero-arrow-down-on-square-stack"
              accent="primary"
            >
              {Stats.format_number(@summary.total_prompt_tokens)}
              <:sub>
                {gettext("cached %{cached} · hit %{rate}",
                  cached: Stats.format_number(@summary.total_cache_read_tokens),
                  rate:
                    Stats.cache_hit_pct(
                      @summary.total_prompt_tokens,
                      @summary.total_cache_read_tokens
                    )
                )}
              </:sub>
            </.kpi_card>

            <.kpi_card
              id="user-kpi-output"
              label={gettext("Output tokens")}
              icon="hero-arrow-up-on-square-stack"
              accent="primary"
            >
              {Stats.format_number(@summary.total_completion_tokens)}
              <:sub>{gettext("avg TPS:") <> " " <> fmt_tps(@summary.avg_tps)}</:sub>
            </.kpi_card>

            <.kpi_card
              id="user-kpi-errors"
              label={gettext("Errors")}
              icon="hero-exclamation-triangle"
              accent={error_accent(@summary.status_breakdown)}
            >
              {Stats.format_number(
                @summary.status_breakdown["4xx"] + @summary.status_breakdown["5xx"]
              )}
              <:sub>
                {gettext("%{rate}% (5 min)",
                  rate: format_rate(@summary.realtime_5min.error_rate)
                )}
              </:sub>
            </.kpi_card>

            <.kpi_card
              id="user-kpi-latency"
              label={gettext("Last request")}
              icon="hero-clock"
              accent="neutral"
            >
              {last_request_label(@summary.last_request_at, @timezone)}
              <:sub>{gettext("avg latency: %{ms}", ms: fmt_ms(@summary.avg_latency_ms))}</:sub>
            </.kpi_card>
          </div>

          <%!-- Per-user FinOps: unit economics, waste and cache posture --%>
          <section id="user-finops" class="space-y-3">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <h2 class="text-sm font-semibold flex items-center gap-2">
                <.icon name="hero-banknotes" class="w-4 h-4 text-base-content/60" />
                {gettext("FinOps — unit economics and waste")}
              </h2>
              <span class="text-[10px] text-base-content/40">{Stats.period_label(@period)}</span>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3">
              <.kpi_card
                id="user-finops-cpr"
                label={gettext("$/req")}
                icon="hero-currency-dollar"
                accent="accent"
              >
                {Stats.cost_per_request(@summary.finops.cost_usd, @summary.finops.requests)}
                <:sub>
                  {gettext("%{count} served reqs",
                    count: Stats.format_number(@summary.finops.requests)
                  )}
                </:sub>
              </.kpi_card>

              <.kpi_card
                id="user-finops-per-1m"
                label={gettext("$/1M tok")}
                icon="hero-calculator"
                accent="accent"
              >
                {Stats.effective_cost_per_1m(
                  @summary.finops.cost_usd,
                  @summary.finops.prompt_tokens,
                  @summary.finops.completion_tokens
                )}
                <:sub>
                  {gettext("%{count} tokens",
                    count:
                      Stats.format_compact(
                        @summary.finops.prompt_tokens + @summary.finops.completion_tokens
                      )
                  )}
                </:sub>
              </.kpi_card>

              <.kpi_card
                id="user-finops-out-in"
                label={gettext("Out/In")}
                icon="hero-arrows-right-left"
                accent="primary"
              >
                {Stats.out_in_ratio(
                  @summary.finops.completion_tokens,
                  @summary.finops.prompt_tokens
                )}
                <:sub>{gettext("completion / prompt")}</:sub>
              </.kpi_card>

              <.kpi_card
                id="user-finops-cache"
                label={gettext("Prompt cache")}
                icon="hero-circle-stack"
                accent="primary"
              >
                {Stats.cache_hit_pct(
                  @summary.finops.prompt_tokens,
                  @summary.finops.cache_read_tokens
                )}
                <:sub>
                  {gettext("%{read} read · %{write} write",
                    read: Stats.format_compact(@summary.finops.cache_read_tokens),
                    write: Stats.format_compact(@summary.finops.cache_creation_tokens)
                  )}
                </:sub>
              </.kpi_card>

              <.kpi_card
                id="user-finops-local-cache"
                label={gettext("Local cache ($0)")}
                icon="hero-bolt"
                accent="success"
              >
                {Stats.format_number(@summary.finops.local_cache_hits)}
                <:sub>
                  {gettext("%{count} prompt tokens saved",
                    count: Stats.format_compact(@summary.finops.prompt_tokens_saved_est)
                  )}
                </:sub>
              </.kpi_card>

              <.kpi_card
                id="user-finops-error-waste"
                label={gettext("Error waste")}
                icon="hero-fire"
                accent="error"
              >
                {Stats.money(@summary.finops.error_cost_usd)}
                <:sub>
                  {gettext("%{share} of spend · %{count} errors",
                    share:
                      Stats.format_percent(
                        Stats.cost_share_pct(
                          @summary.finops.error_cost_usd,
                          @summary.finops.cost_usd
                        ) / 100
                      ),
                    count: Stats.format_number(@summary.finops.error_requests)
                  )}
                </:sub>
              </.kpi_card>

              <.kpi_card
                id="user-finops-thinking"
                label={gettext("Thinking tax")}
                icon="hero-light-bulb"
                accent="warning"
              >
                {Stats.money(@summary.finops.think_cost_usd)}
                <:sub>
                  {gettext("%{share} of spend · %{count} think reqs",
                    share:
                      Stats.format_percent(
                        Stats.cost_share_pct(
                          @summary.finops.think_cost_usd,
                          @summary.finops.cost_usd
                        ) / 100
                      ),
                    count: Stats.format_number(@summary.finops.think_requests)
                  )}
                </:sub>
              </.kpi_card>

              <.kpi_card
                id="user-finops-topups"
                label={gettext("Top-ups vs quota")}
                icon="hero-arrow-up-circle"
                accent="neutral"
              >
                {Stats.money(@summary.finops.topup_cost_usd)}
                <:sub>
                  {gettext("%{count} reqs paid with a top-up",
                    count: Stats.format_number(@summary.finops.topup_requests)
                  )}
                </:sub>
              </.kpi_card>
            </div>

            <%!-- Burn: average daily spend of the window and its 30d run rate --%>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <.kpi_card
                id="user-finops-burn-day"
                label={gettext("$/day burn")}
                icon="hero-fire"
                accent="accent"
              >
                {Stats.money(@burn.per_day)}
                <:sub>
                  {gettext("average per day · %{days}-day window", days: fmt_days(@burn.days))}
                </:sub>
              </.kpi_card>

              <.kpi_card
                id="user-finops-projection"
                label={gettext("30-day projection")}
                icon="hero-chart-bar"
                accent="warning"
              >
                {Stats.money(@burn.projection_30d)}
                <:sub>
                  {gettext("at the current burn rate")}
                </:sub>
              </.kpi_card>
            </div>
          </section>

          <%!-- Spend / volume trend (hourly for a single day, daily beyond) --%>
          <FinopsCharts.dual_trend_chart
            :if={@series != []}
            id="user-finops-trend"
            title={gettext("Spend and volume trend")}
            hint={
              gettext(
                "This user's traffic in the selected window, bucketed by %{bucket} in the local timezone.",
                bucket: if(hourly_period?(@period), do: gettext("hour"), else: gettext("day"))
              )
            }
            series={@series}
            metric={@trend_metric}
            toggle_event="user_trend_metric"
          />

          <%!-- Memberships + Status breakdown + Top models --%>
          <div class="grid grid-cols-1 lg:grid-cols-3 gap-3">
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4">
                <h3 class="text-sm font-semibold mb-2">{gettext("Memberships (consolidated)")}</h3>
                <%= if @memberships == [] do %>
                  <p class="text-xs text-base-content/40">
                    {gettext("No memberships — user without access.")}
                  </p>
                <% else %>
                  <ul class="space-y-1 text-sm">
                    <li :for={m <- @memberships} class="flex items-center justify-between">
                      <span>
                        <.link
                          :if={m.group}
                          navigate={~p"/stats/profiles/#{m.group.id}"}
                          class="link link-hover hover:text-primary"
                          id={"membership-group-#{m.group.id}"}
                        >
                          {m.group.name}
                        </.link>
                        <span :if={!m.group}>—</span>
                      </span>
                      <span class="badge badge-sm badge-ghost">
                        {if m.api_key, do: m.api_key.key_prefix, else: "—"}
                      </span>
                    </li>
                  </ul>
                <% end %>
              </div>
            </div>
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="user-status-breakdown">
              <div class="card-body p-4">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-sm font-semibold">{gettext("Status breakdown")}</h3>
                  <span class="text-[10px] text-base-content/40">
                    {Stats.period_label(@period)}
                  </span>
                </div>
                <div class="space-y-2">
                  <%!-- Una fila por clase de status: el badge ES la etiqueta, así
                       que no hace falta un componente local (el `status_row/1`
                       compartido es privado de `ServiceStatsBody`). --%>
                  <div
                    :for={
                      {class_label, badge} <- [
                        {"2xx", "badge-success"},
                        {"4xx", "badge-warning"},
                        {"5xx", "badge-error"}
                      ]
                    }
                    class="flex items-center justify-between"
                    id={"user-status-#{class_label}"}
                  >
                    <span class={["badge badge-sm", badge]}>{class_label}</span>
                    <span class="text-sm font-mono">
                      {Integer.to_string(Map.get(@summary.status_breakdown, class_label, 0))}
                    </span>
                  </div>
                </div>
              </div>
            </div>
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="user-top-models">
              <div class="card-body p-4">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-sm font-semibold">{gettext("Top models")}</h3>
                  <span class="text-[10px] text-base-content/40">
                    {Stats.period_label(@period)}
                  </span>
                </div>
                <%= if @summary.top_models == [] do %>
                  <p class="text-xs text-base-content/40">
                    {gettext("No requests in this period.")}
                  </p>
                <% else %>
                  <ol class="space-y-1">
                    <li
                      :for={row <- @summary.top_models}
                      class="flex items-center justify-between text-sm"
                    >
                      <span class="font-mono">{row.model_requested || "—"}</span>
                      <span class="flex items-center gap-2">
                        <span class="font-mono text-xs text-base-content/60">
                          {fmt_money(row.total_cost_usd)}
                        </span>
                        <span class="badge badge-sm badge-ghost">
                          {Integer.to_string(row.count)}
                        </span>
                      </span>
                    </li>
                  </ol>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Desglose por agente y proveedor del usuario --%>
          <div
            :if={@user_breakdowns.agents != [] or @user_breakdowns.providers != []}
            class="grid grid-cols-1 lg:grid-cols-2 gap-3"
            id="user-breakdowns-grid"
          >
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="user-agents-breakdown">
              <div class="card-body p-4">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-sm font-semibold">{gettext("Agents used")}</h3>
                  <span class="text-[10px] text-base-content/40">
                    {Stats.period_label(@period)}
                  </span>
                </div>
                <%= if @user_breakdowns.agents == [] do %>
                  <p class="text-xs text-base-content/40">
                    {gettext("No agent data in this period.")}
                  </p>
                <% else %>
                  <ul class="divide-y divide-base-200/60">
                    <li
                      :for={row <- @user_breakdowns.agents}
                      class="py-1.5 flex items-center justify-between gap-2 text-xs"
                    >
                      <div class="flex items-center gap-2 min-w-0">
                        <img
                          :if={row.logo}
                          src={row.logo}
                          alt=""
                          class="w-4 h-4 object-contain shrink-0"
                        />
                        <.icon
                          :if={!row.logo}
                          name={row.icon}
                          class="w-4 h-4 text-base-content/60 shrink-0"
                        />
                        <.link
                          navigate={~p"/stats/agents/#{row.key}?period=#{@period}"}
                          class="link link-hover font-medium truncate"
                        >
                          {row.label}
                        </.link>
                      </div>
                      <div class="flex items-center gap-3 shrink-0 font-mono tabular-nums">
                        <span class="text-base-content/60">
                          {Stats.format_number(row.request_count)} req
                        </span>
                        <span class="text-base-content/60">
                          {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)} cache
                        </span>
                        <span class="font-semibold text-warning">{fmt_money(row.cost_usd)}</span>
                      </div>
                    </li>
                  </ul>
                <% end %>
              </div>
            </div>

            <div
              class="card bg-base-100 border border-base-300 shadow-sm"
              id="user-providers-breakdown"
            >
              <div class="card-body p-4">
                <div class="flex items-center justify-between mb-2">
                  <h3 class="text-sm font-semibold">{gettext("Providers used")}</h3>
                  <span class="text-[10px] text-base-content/40">
                    {Stats.period_label(@period)}
                  </span>
                </div>
                <%= if @user_breakdowns.providers == [] do %>
                  <p class="text-xs text-base-content/40">
                    {gettext("No provider data in this period.")}
                  </p>
                <% else %>
                  <ul class="divide-y divide-base-200/60">
                    <li
                      :for={row <- @user_breakdowns.providers}
                      class="py-1.5 flex items-center justify-between gap-2 text-xs"
                    >
                      <div class="flex items-center gap-2 min-w-0">
                        <Stats.provider_logo logo_url={row.provider_logo_url} />
                        <%= if row.provider_id do %>
                          <.link
                            navigate={~p"/stats/providers/#{row.provider_id}?period=#{@period}"}
                            class="link link-hover font-medium truncate"
                          >
                            {row.provider_name}
                          </.link>
                        <% else %>
                          <span class="font-medium truncate">{row.provider_name}</span>
                        <% end %>
                      </div>
                      <div class="flex items-center gap-3 shrink-0 font-mono tabular-nums">
                        <span class="text-base-content/60">
                          {Stats.format_number(row.request_count)} req
                        </span>
                        <span class="text-base-content/60">
                          {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)} cache
                        </span>
                        <span class="font-semibold text-warning">{fmt_money(row.cost_usd)}</span>
                      </div>
                    </li>
                  </ul>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Filter form --%>
          <.form
            for={@form}
            id="user-stats-filter-form"
            phx-change="filter"
            class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3"
          >
            <.input
              field={@form[:status_class]}
              type="select"
              prompt={gettext("All")}
              options={[{"2xx", "2xx"}, {"4xx", "4xx"}, {"5xx", "5xx"}]}
              label={gettext("Status")}
            />
            <.input
              field={@form[:streaming]}
              type="select"
              prompt={gettext("All")}
              options={[{gettext("Yes"), "true"}, {gettext("No"), "false"}]}
              label={gettext("Streaming")}
            />
            <.input
              field={@form[:model_search]}
              type="text"
              label={gettext("Model")}
            />
            <.input
              field={@form[:from]}
              type="date"
              label={gettext("From")}
            />
            <.input
              field={@form[:to]}
              type="date"
              label={gettext("To")}
            />
          </.form>

          <%!-- Logs table (stream) --%>
          <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
            <.table
              id="user-stats-logs"
              rows={@streams.logs}
              row_item={fn {_id, log} -> log end}
              empty?={@logs_empty?}
            >
              <:col :let={log} label={gettext("Date")}>
                <span class="whitespace-nowrap text-sm">
                  {TokengateWeb.TimezoneHelper.format_datetime(log.inserted_at, @timezone)}
                </span>
              </:col>
              <:col :let={log} label={gettext("Model")}>
                <span class="text-sm">{model_display(log.model_requested, log.model_responded)}</span>
              </:col>
              <:col :let={log} label={gettext("Agent")}>
                <span class="text-sm">{log.client_agent || "—"}</span>
              </:col>
              <:col :let={log} label={gettext("Streaming")}>
                {if log.streaming, do: gettext("Yes"), else: gettext("No")}
              </:col>
              <:col :let={log} label={gettext("Status")}>
                <span class={["badge badge-sm", status_badge(log.status_code)]}>
                  {Integer.to_string(log.status_code)}
                </span>
              </:col>
              <:col :let={log} label={gettext("Input")} align="right">
                <span class="text-sm">{Stats.format_number(log.prompt_tokens || 0)}</span>
              </:col>
              <:col :let={log} label={gettext("Output")} align="right">
                <span class="text-sm">{Stats.format_number(log.completion_tokens || 0)}</span>
              </:col>
              <:col :let={log} label={gettext("Cost")} align="right">
                <span class="text-sm font-mono">${format_cost(log.provider_cost_usd)}</span>
              </:col>
              <:col :let={log} label={gettext("Latency")} align="right">
                <span class="text-sm">{Stats.format_number(log.latency_ms || 0)} ms</span>
              </:col>
              <:empty>
                <.icon name="hero-inbox" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                <p>
                  <%= if @memberships == [] do %>
                    {gettext("This user has no memberships — there are no logs to show.")}
                  <% else %>
                    {gettext("No requests with the current filters.")}
                  <% end %>
                </p>
              </:empty>
            </.table>
          </div>

          <%= if @has_more do %>
            <div class="flex justify-center">
              <button
                phx-click="load_more"
                class="btn btn-ghost btn-sm"
                id="load-more-user-stats-logs"
              >
                {gettext("Load more")}
              </button>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  ## Presentation helpers -------------------------------------------------

  defp error_accent(%{"5xx" => n}) when n > 0, do: "error"
  defp error_accent(%{"4xx" => n}) when n > 0, do: "warning"
  defp error_accent(_), do: "neutral"

  defp fmt_days(days) when days == 1.0, do: "1"

  defp fmt_days(days) do
    :erlang.float_to_binary(Float.round(days * 10) / 10, [:compact, {:decimals, 1}])
  end

  defp format_rate(n) when is_integer(n), do: Integer.to_string(n)

  defp format_rate(f) when is_float(f),
    do: :erlang.float_to_binary(f, [:compact, {:decimals, 1}])

  defp format_rate(_), do: "0"
end
