defmodule TokengateWeb.UserStatsLive do
  @moduledoc """
  Admin-only consolidated stats page for a **user**, aggregating every
  group membership the user holds.

  Shows aggregated KPI cards (requests, cost, tokens, top models, status
  breakdown, last request) for the canonical period (`?period=`, default
  `"week"` via `Tokengate.Periods`) and a paginated stream of the user's
  recent logs across all memberships. Data loads asynchronously via
  `start_async/3`; real-time updates arrive via `logs:new` PubSub.

  Path: `/stats/users/:user_id`

  Admin-only by router; defense-in-depth `require_admin_hook/1` rejects
  event traffic from non-admins (a malicious client could otherwise
  fire events directly over the WebSocket).
  """

  use TokengateWeb, :live_view
  require Logger

  import TokengateWeb.KpiHelpers, only: [kpi_card: 1]

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Periods
  alias TokengateWeb.KpiHelpers
  alias TokengateWeb.ServiceStatsBody
  alias TokengateWeb.StatsHelpers, as: Stats

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
          |> assign(:summary, default_summary())
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

      if log_matches_filters?(log, filters, timezone) do
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
        |> ServiceStatsBody.parse_date_filters(timezone)
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

  # Logs.list_logs/1 doesn't tolerate empty-string values for boolean
  # fields (streaming) — strip them before forwarding.
  defp drop_empty_filters(filters) do
    filters
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp default_filters do
    %{
      "status_class" => "",
      "streaming" => "",
      "from" => "",
      "to" => "",
      "model_search" => ""
    }
  end

  defp default_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      request_count: 0,
      avg_latency_ms: nil,
      avg_tps: 0.0,
      avg_ttft_ms: nil,
      status_breakdown: %{"2xx" => 0, "4xx" => 0, "5xx" => 0},
      top_models: [],
      last_request_at: nil,
      realtime_5min: %{request_count: 0, error_count: 0, avg_latency_ms: nil, error_rate: 0.0}
    }
  end

  ## Filter helpers -------------------------------------------------------

  defp log_matches_filters?(log, filters, timezone) do
    status_class = filters["status_class"]
    streaming = filters["streaming"]
    search = filters["model_search"]

    cond do
      status_class not in [nil, ""] and not status_class_match?(log.status_code, status_class) ->
        false

      streaming not in [nil, ""] and not streaming_match?(log.streaming, streaming) ->
        false

      search not in [nil, ""] and
          not (String.contains?(log.model_requested || "", search) or
                   String.contains?(log.model_responded || "", search)) ->
        false

      true ->
        date_range_match?(log.inserted_at, filters["from"], filters["to"], timezone)
    end
  end

  defp status_class_match?(_, ""), do: true
  defp status_class_match?(status, "2xx"), do: status >= 200 and status < 300
  defp status_class_match?(status, "4xx"), do: status >= 400 and status < 500
  defp status_class_match?(status, "5xx"), do: status >= 500 and status < 600
  defp status_class_match?(_, _), do: true

  defp streaming_match?(_, ""), do: true
  defp streaming_match?(streaming, "true"), do: streaming == true
  defp streaming_match?(streaming, "false"), do: streaming == false
  defp streaming_match?(_, _), do: true

  defp date_range_match?(_dt, "", "", _timezone), do: true

  defp date_range_match?(dt, from, to, timezone) do
    after_from =
      case parse_date_string(from, timezone) do
        nil -> true
        from_dt -> DateTime.compare(dt, from_dt) != :lt
      end

    before_to =
      case parse_date_string(to, timezone, :end_of_day) do
        nil -> true
        to_dt -> DateTime.compare(dt, to_dt) != :gt
      end

    after_from and before_to
  end

  defp parse_date_string(date_str, timezone, mode \\ :start_of_day) do
    TokengateWeb.TimezoneHelper.parse_local_date(date_str, timezone, mode)
  end

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
                    KpiHelpers.format_hit_rate(
                      KpiHelpers.cache_hit_rate(
                        @summary.total_cache_read_tokens,
                        @summary.total_prompt_tokens
                      )
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
                  <.status_row
                    class_label="2xx"
                    count={@summary.status_breakdown["2xx"]}
                    tone="success"
                  />
                  <.status_row
                    class_label="4xx"
                    count={@summary.status_breakdown["4xx"]}
                    tone="warning"
                  />
                  <.status_row
                    class_label="5xx"
                    count={@summary.status_breakdown["5xx"]}
                    tone="error"
                  />
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

  attr :class_label, :string, required: true
  attr :count, :integer, default: 0
  attr :tone, :string, default: "default"

  defp status_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <span class={["badge badge-sm", row_tone(@tone)]}>{@class_label}</span>
      <span class="text-sm font-mono">{Integer.to_string(@count)}</span>
    </div>
    """
  end

  defp row_tone("error"), do: "badge-error"
  defp row_tone("warning"), do: "badge-warning"
  defp row_tone("success"), do: "badge-success"
  defp row_tone(_), do: "badge-ghost"

  defp error_accent(%{"5xx" => n}) when n > 0, do: "error"
  defp error_accent(%{"4xx" => n}) when n > 0, do: "warning"
  defp error_accent(_), do: "neutral"

  ## Format helpers -------------------------------------------------------

  defp format_cost(%Decimal{} = d) do
    d |> Decimal.to_float() |> :erlang.float_to_binary([:compact, {:decimals, 6}])
  end

  defp format_cost(nil), do: "—"

  defp fmt_money(%Decimal{} = d), do: Stats.money(d)

  defp fmt_money(_), do: "$0"

  defp fmt_tps(nil), do: "—"
  defp fmt_tps(tps) when tps in [+0.0, -0.0, 0.0], do: "—"

  defp fmt_tps(tps) when is_number(tps) do
    tps |> Float.round(1) |> :erlang.float_to_binary([:compact, {:decimals, 1}])
  end

  defp fmt_tps(_), do: "—"

  defp fmt_ms(nil), do: "—"
  defp fmt_ms(ms) when is_number(ms), do: "#{Float.round(ms, 0) |> trunc()} ms"
  defp fmt_ms(_), do: "—"

  defp model_display(req, resp) do
    cond do
      is_binary(resp) and resp != "" and resp != req -> "#{req} → #{resp}"
      true -> req || "—"
    end
  end

  defp status_badge(code) when is_integer(code) and code >= 200 and code < 300,
    do: "badge-success"

  defp status_badge(code) when is_integer(code) and code >= 400 and code < 500,
    do: "badge-warning"

  defp status_badge(code) when is_integer(code) and code >= 500 and code < 600, do: "badge-error"
  defp status_badge(_), do: "badge-ghost"

  defp last_request_label(nil, _tz), do: "—"

  defp last_request_label(%DateTime{} = dt, tz),
    do: TokengateWeb.TimezoneHelper.format_datetime(dt, tz)

  defp format_rate(n) when is_integer(n), do: Integer.to_string(n)

  defp format_rate(f) when is_float(f),
    do: :erlang.float_to_binary(f, [:compact, {:decimals, 1}])

  defp format_rate(_), do: "0"
end
