defmodule TokengateWeb.LogsLive do
  @moduledoc false
  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Tokengate.{Accounts, Logs}
  alias Tokengate.Logs.Inflight
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Providers
  alias Tokengate.Repo

  @page_size 50
  @pubsub Tokengate.PubSub
  @logs_topic "logs:new"
  @summary_refresh_interval_ms 2_000
  @summary_tick_interval_ms 5_000
  @inflight_refresh_interval_ms 3_000
  @system_metrics_tick_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    scope_member_ids = resolve_scope_member_ids(user)

    socket =
      socket
      |> assign(:page_title, "Logs · Tokengate")
      |> assign(:page_size, @page_size)
      |> assign(:has_more, false)
      |> assign(:cursor, nil)
      |> assign(:scope_member_ids, scope_member_ids)
      |> assign(:filters, default_filters())
      |> assign(:form, to_form(default_filters(), as: :filter))
      |> assign(:summary, empty_summary())
      |> assign(:top_models, [])
      |> assign(:top_users, [])
      |> assign(:summary_refresh_scheduled, false)
      |> assign(:last_seen_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> assign(:online_users, [])
      |> assign(:api_inflight, 0)
      |> assign(:pending, [])
      |> assign(:model_options, model_options())
      |> assign(:team_options, team_options())
      |> assign(:is_admin, user.global_role == "admin")
      |> assign(:error_credentials, [])
      |> assign(:breaker_alerts, [])
      |> assign(:cred_error_counts, [])
      |> assign(:budget_exhausted, [])
      |> assign(:budget_activity, %{})
      |> assign(:system_metrics, empty_system_metrics())
      |> require_admin_hook()

    socket = load_logs(socket, :reset)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @logs_topic)
      Phoenix.PubSub.subscribe(@pubsub, Inflight.topic())
      Phoenix.PubSub.subscribe(@pubsub, TokengateWeb.Presence.topic())
      Phoenix.PubSub.subscribe(@pubsub, "alerts")

      send(self(), :refresh_inflight)

      # Rolling-window KPIs decay with time (req/min drops even when no new
      # logs arrive), so refresh them on a fixed tick, not only on new logs.
      :timer.send_interval(@summary_tick_interval_ms, :refresh_summary)

      # System monitor (RAM/CPU/processes/DB) refreshes on its own tick.
      :timer.send_interval(@system_metrics_tick_ms, :refresh_system_metrics)

      pending = visible_pending(socket.assigns)

      socket =
        socket
        |> assign(:online_users, TokengateWeb.Presence.list_online())
        |> assign(:api_inflight, Inflight.count())
        |> assign(:top_models, top_models_card(socket.assigns))
        |> assign(:top_users, top_users_card(socket.assigns))
        |> assign(:pending, pending)
        |> assign(:system_metrics, collect_system_metrics())
        |> load_alert_data()

      # Insert existing pending entries at the top of the logs stream
      socket =
        Enum.reduce(pending, socket, fn entry, acc ->
          stream_insert(acc, :logs, pending_entry_to_log(entry), at: 0)
        end)

      {:ok, socket}
    else
      {:ok, load_alert_data(socket)}
    end
  end

  # Defense-in-depth: the router already gates this LiveView behind
  # live_session :admin, but a malicious client could fire events directly
  # over the WebSocket. Halt every event for non-admins.
  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  ## Real-time -------------------------------------------------------------

  @impl true
  def handle_info({:new_log, log}, socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    # Only prepend if the log falls within the user's scope and filters.
    if log_in_scope?(log, socket.assigns[:scope_member_ids]) and
         log_matches_filters?(log, socket.assigns[:filters], timezone) do
      socket =
        socket
        |> stream_insert(:logs, log, at: 0)
        |> assign(:last_seen_at, max_datetime(log.inserted_at, socket.assigns[:last_seen_at]))

      {:noreply, schedule_summary_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_summary, socket) do
    {:noreply,
     socket
     |> assign(:summary_refresh_scheduled, false)
     |> refresh_summary()}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online_users, TokengateWeb.Presence.list_online())}
  end

  def handle_info(:refresh_inflight, socket) do
    Process.send_after(self(), :refresh_inflight, @inflight_refresh_interval_ms)

    {:noreply,
     socket
     |> assign(:api_inflight, visible_inflight_count(socket.assigns))
     |> assign(:top_models, top_models_card(socket.assigns))
     |> assign(:top_users, top_users_card(socket.assigns))}
  end

  def handle_info(:refresh_system_metrics, socket) do
    {:noreply, assign(socket, :system_metrics, collect_system_metrics())}
  end

  def handle_info({:inflight_started, entry}, socket) do
    if pending_visible?(entry, socket.assigns) do
      socket =
        socket
        |> assign(:pending, [entry | socket.assigns[:pending]])
        |> assign(:api_inflight, socket.assigns[:api_inflight] + 1)
        |> stream_insert(:logs, pending_entry_to_log(entry), at: 0)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:inflight_done, id}, socket) do
    pending_before = socket.assigns[:pending]
    removed? = Enum.any?(pending_before, &(&1.id == id))

    socket =
      socket
      |> assign(:pending, Enum.reject(pending_before, &(&1.id == id)))
      |> update(:api_inflight, fn n -> if removed?, do: max(n - 1, 0), else: n end)
      |> stream_delete(:logs, %{id: "pending-#{id}"})

    {:noreply, socket}
  end

  def handle_info({:breaker_opened, _credential_id, reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Circuit breaker abierto (#{reason_label(reason)})")
     |> load_alert_data()}
  end

  def handle_info({:credential_error, _credential_id, reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Credencial desactivada (#{reason_label(reason)})")
     |> load_alert_data()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Coalesce summary refreshes: under load every new log would otherwise run
  # a cost_summary query per connected LiveView. Cap at one per interval.
  defp schedule_summary_refresh(socket) do
    if socket.assigns[:summary_refresh_scheduled] do
      socket
    else
      Process.send_after(self(), :refresh_summary, @summary_refresh_interval_ms)
      assign(socket, :summary_refresh_scheduled, true)
    end
  end

  defp log_in_scope?(_log, nil), do: true

  defp log_in_scope?(log, member_ids) when is_list(member_ids) do
    log.team_member_id in member_ids
  end

  defp log_matches_filters?(log, filters, timezone) do
    agent = filters["agent_type"]
    status_class = filters["status_class"]
    streaming = filters["streaming"]
    model_search = filters["model_search"]
    team_id = filters["team_id"]
    error_reason = filters["error_reason"]

    agent in ["", nil, log.agent_type] and
      status_class_match?(log.status_code, status_class) and
      streaming_match?(log.streaming, streaming) and
      model_match?(log, model_search) and
      team_id_match?(log, team_id) and
      error_reason_match?(log, error_reason) and
      date_range_match?(log.inserted_at, filters["from"], filters["to"], timezone)
  end

  defp team_id_match?(_log, ""), do: true
  defp team_id_match?(_log, nil), do: true

  defp team_id_match?(log, team_id) do
    log.team_member && log.team_member.team && log.team_member.team.id == team_id
  end

  defp error_reason_match?(_log, ""), do: true
  defp error_reason_match?(_log, nil), do: true
  defp error_reason_match?(log, reason), do: log.error_reason == reason

  defp status_class_match?(_status, ""), do: true
  defp status_class_match?(_status, nil), do: true
  defp status_class_match?(status, "2xx"), do: status >= 200 and status < 300
  defp status_class_match?(status, "4xx"), do: status >= 400 and status < 500
  defp status_class_match?(status, "5xx"), do: status >= 500 and status < 600
  defp status_class_match?(_, _), do: true

  defp streaming_match?(_streaming, ""), do: true
  defp streaming_match?(_streaming, nil), do: true
  defp streaming_match?(streaming, "true"), do: streaming == true
  defp streaming_match?(streaming, "false"), do: streaming == false
  defp streaming_match?(_, _), do: true

  defp model_match?(_log, ""), do: true
  defp model_match?(_log, nil), do: true

  defp model_match?(log, search) do
    String.contains?(log.model_requested || "", search) or
      String.contains?(log.model_responded || "", search)
  end

  ## Pending (in-flight) visibility -------------------------------------------

  # In-flight entries that pass scope + current filters. Status-class filter
  # doesn't apply (pending has no status yet).
  defp visible_pending(assigns) do
    Inflight.list()
    |> Enum.filter(&pending_visible?(&1, assigns))
  end

  # Counter shown in the "En vuelo" KPI card. Matches the rows in the
  # "En vuelo ahora" table exactly so they never disagree.
  defp visible_inflight_count(assigns) do
    visible_pending(assigns) |> length()
  end

  # Top-cards: build a filter map that combines the user's scope
  # (team_member_ids) with the active UI filters so the cards never leak
  # rows the table would hide.
  defp top_card_filters(assigns) do
    filters = assigns[:filters] || %{}

    base =
      case assigns[:scope_member_ids] do
        nil -> %{}
        ids -> %{team_member_ids: ids}
      end

    base
    |> maybe_put_filter(filters, "agent_type", :agent_type)
    |> maybe_put_filter(filters, "model_search", :model_search)
    |> maybe_put_filter(filters, "team_id", :team_id)
    |> maybe_put_filter(filters, "streaming", :streaming)
    |> maybe_put_filter(filters, "error_reason", :error_reason)
  end

  defp maybe_put_filter(acc, filters, key, field) do
    case Map.get(filters, key) do
      nil -> acc
      "" -> acc
      value -> Map.put(acc, field, value)
    end
  end

  defp top_models_card(assigns) do
    Logs.top_models_last_minutes(1, 3, top_card_filters(assigns))
  end

  defp top_users_card(assigns) do
    Logs.top_users_last_minutes(1, 3, top_card_filters(assigns))
  end

  # Converts an Inflight entry to the log shape so it renders inside the
  # main logs table. `__pending__: true` flags the row for special styling.
  defp pending_entry_to_log(entry) do
    %{
      id: "pending-#{entry.id}",
      inserted_at: entry.started_at,
      model_requested: entry.model_requested,
      model_responded: nil,
      team_member: %{user: %{email: entry.user_email}, team: %{name: entry.team_name}},
      client_agent: entry.client_agent,
      api_key_prefix: entry.api_key_prefix,
      provider: %{name: entry.provider_name},
      provider_key_prefix: entry.provider_key_suffix,
      provider_status_code: nil,
      error_reason: nil,
      error_message: nil,
      status_code: nil,
      think: entry.think,
      effort: entry.effort,
      streaming: entry.streaming,
      prompt_tokens: nil,
      completion_tokens: nil,
      cache_read_tokens: nil,
      cache_creation_tokens: nil,
      latency_ms: nil,
      ttft_ms: nil,
      provider_cost_usd: nil,
      __pending__: true
    }
  end

  defp pending_visible?(entry, assigns) do
    filters = assigns[:filters]

    in_scope =
      case assigns[:scope_member_ids] do
        nil -> true
        ids -> entry.team_member_id in ids
      end

    agent = filters["agent_type"]
    streaming = filters["streaming"]
    model_search = filters["model_search"]
    team_id = filters["team_id"]

    in_scope and
      agent in ["", nil, entry.agent_type] and
      streaming_match?(entry.streaming, streaming) and
      pending_model_match?(entry, model_search) and
      team_id in ["", nil, entry.team_id] and
      date_range_match?(
        entry.started_at,
        filters["from"],
        filters["to"],
        assigns[:timezone] || "Etc/UTC"
      )
  end

  defp pending_model_match?(_entry, ""), do: true
  defp pending_model_match?(_entry, nil), do: true

  defp pending_model_match?(entry, search) do
    String.contains?(entry.model_requested || "", search)
  end

  defp model_options do
    Providers.list_model_aliases()
    |> Enum.map(fn alias_ -> {alias_.display_name || alias_.name, alias_.name} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp team_options do
    Accounts.list_teams()
    |> Enum.map(fn team -> {team.name, team.id} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp date_range_match?(_dt, "", "", _timezone), do: true
  defp date_range_match?(_dt, nil, nil, _timezone), do: true

  defp date_range_match?(dt, from, to, timezone) do
    after_from? =
      case parse_date_string(from, timezone) do
        nil -> true
        from_dt -> DateTime.compare(dt, from_dt) != :lt
      end

    before_to? =
      case parse_date_string(to, timezone, :end_of_day) do
        nil -> true
        to_dt -> DateTime.compare(dt, to_dt) != :gt
      end

    after_from? and before_to?
  end

  defp parse_date_string(date_str, timezone, mode \\ :start_of_day)

  defp parse_date_string("", _tz, _mode), do: nil
  defp parse_date_string(nil, _tz, _mode), do: nil

  defp parse_date_string(date_str, timezone, mode) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        time =
          case mode do
            :start_of_day -> ~T[00:00:00]
            :end_of_day -> ~T[23:59:59]
          end

        date
        |> DateTime.new!(time, timezone)
        |> DateTime.shift_zone!("Etc/UTC")

      _ ->
        nil
    end
  end

  defp max_datetime(dt1, dt2) do
    if DateTime.compare(dt1, dt2) == :gt, do: dt1, else: dt2
  end

  defp refresh_summary(socket) do
    summary =
      Logs.realtime_summary(build_filters(socket, include_limit: false, include_cursor: false))

    socket |> assign(:summary, summary)
  end

  ## Scope resolution ------------------------------------------------------

  defp resolve_scope_member_ids(%{global_role: "admin"}) do
    nil
  end

  defp resolve_scope_member_ids(user) do
    memberships = Accounts.list_team_members_for_user(user.id)
    Enum.map(memberships, & &1.id)
  end

  ## Data loading ----------------------------------------------------------

  defp load_logs_with_pending(socket, :reset) do
    socket = load_logs(socket, :reset)

    # Re-insert pending entries at the top after stream reset
    pending = socket.assigns[:pending] || []

    Enum.reduce(pending, socket, fn entry, acc ->
      stream_insert(acc, :logs, pending_entry_to_log(entry), at: 0)
    end)
  end

  defp load_logs(socket, mode) do
    list_filters = build_filters(socket, include_cursor: mode == :more)

    logs = Logs.list_logs(list_filters)

    summary =
      Logs.realtime_summary(build_filters(socket, include_limit: false, include_cursor: false))

    has_more = length(logs) == @page_size

    socket =
      socket
      |> assign(:summary, summary)
      |> assign(:has_more, has_more)

    socket =
      case mode do
        :reset -> stream(socket, :logs, logs, reset: true)
        :more -> stream(socket, :logs, logs)
      end

    case logs do
      [] ->
        socket

      _ ->
        oldest = List.last(logs)
        assign(socket, :cursor, oldest.inserted_at)
    end
  end

  ## Filter building -------------------------------------------------------

  defp default_filters do
    %{
      "status_class" => "",
      "streaming" => "",
      "from" => "",
      "to" => "",
      "model_search" => "",
      "team_id" => "",
      "error_reason" => ""
    }
  end

  defp build_filters(socket, opts) do
    include_cursor = Keyword.get(opts, :include_cursor, false)
    include_limit = Keyword.get(opts, :include_limit, true)
    form_filters = socket.assigns[:filters]
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    base =
      %{}
      |> maybe_put(:status_class, form_filters["status_class"])
      |> maybe_put(:streaming, parse_bool(form_filters["streaming"]))
      |> maybe_put(:model_search, form_filters["model_search"])
      |> maybe_put_team_id(form_filters["team_id"])
      |> maybe_put(:error_reason, form_filters["error_reason"])
      |> maybe_put(:from, parse_from_date(form_filters["from"], timezone))
      |> maybe_put(:to, parse_to_date(form_filters["to"], timezone))
      |> maybe_put_scope(socket.assigns[:scope_member_ids])

    base =
      if include_cursor do
        maybe_put(base, :before, socket.assigns[:cursor])
      else
        base
      end

    if include_limit, do: Map.put(base, :limit, @page_size), else: base
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_team_id(map, ""), do: map
  defp maybe_put_team_id(map, nil), do: map
  defp maybe_put_team_id(map, team_id), do: Map.put(map, :team_id, team_id)

  defp maybe_put_scope(map, nil), do: map
  defp maybe_put_scope(map, ids), do: Map.put(map, :team_member_ids, ids)

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp parse_from_date("", _timezone), do: nil
  defp parse_from_date(nil, _timezone), do: nil

  defp parse_from_date(date_str, timezone) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        date
        |> DateTime.new!(~T[00:00:00], timezone)
        |> DateTime.shift_zone!("Etc/UTC")

      _ ->
        nil
    end
  end

  defp parse_to_date("", _timezone), do: nil
  defp parse_to_date(nil, _timezone), do: nil

  defp parse_to_date(date_str, timezone) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        # End of the LOCAL day (23:59:59 local) converted to UTC
        date
        |> DateTime.new!(~T[23:59:59], timezone)
        |> DateTime.shift_zone!("Etc/UTC")

      _ ->
        nil
    end
  end

  defp empty_summary do
    %{
      request_count: 0,
      req_per_min: 0.0,
      avg_latency_ms: nil,
      error_count: 0,
      error_rate: 0.0
    }
  end

  ## System monitor ------------------------------------------------------------

  defp empty_system_metrics do
    %{
      memory: %{total: 0, processes: 0, ets: 0, atom: 0, binary: 0},
      process_count: 0,
      process_limit: 0,
      run_queue: 0,
      schedulers: 0,
      schedulers_online: 0,
      db_pool_size: 0,
      db_query_ms: nil,
      io_in: 0,
      io_out: 0,
      uptime_ms: 0
    }
  end

  # Collects live VM + DB stats. Pure OTP/Erlang introspection — no external
  # deps. CPU load is approximated by run_queue vs schedulers (a saturated VM
  # has a run queue longer than its online schedulers); process_count and
  # memory are instantaneous. DB health is a timed SELECT 1 probe.
  defp collect_system_metrics do
    # :erlang.memory/0 returns a keyword list, not a map.
    mem = :erlang.memory()

    {db_pool_size, db_query_ms} = db_pool_stats()

    {{input_bytes, output_bytes}, uptime_ms} = io_and_uptime()

    %{
      memory: %{
        total: Keyword.get(mem, :total, 0),
        processes: Keyword.get(mem, :processes, 0),
        ets: Keyword.get(mem, :ets, 0),
        atom: Keyword.get(mem, :atom, 0),
        binary: Keyword.get(mem, :binary, 0)
      },
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      run_queue: :erlang.statistics(:run_queue),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      db_pool_size: db_pool_size,
      db_query_ms: db_query_ms,
      io_in: input_bytes,
      io_out: output_bytes,
      uptime_ms: uptime_ms
    }
  end

  # DB pool stats. We report the configured pool_size plus a live health probe:
  # a trivial `SELECT 1` timed in ms tells us the pool is answering and how
  # fast — far more useful than a guessed "busy" count. On any failure (DB
  # down, pool exhausted) we report pool_size with a nil latency.
  defp db_pool_stats do
    config = Repo.config()
    pool_size = Keyword.get(config, :pool_size, 10)

    latency_ms =
      try do
        t0 = System.monotonic_time(:millisecond)
        _ = Repo.query!("SELECT 1", [], timeout: 2_000)
        System.monotonic_time(:millisecond) - t0
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    {pool_size, latency_ms}
  end

  defp io_and_uptime do
    {{:input, in_b}, {:output, out_b}} = :erlang.statistics(:io)
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    {{in_b, out_b}, uptime_ms}
  end

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    filter_params =
      params
      |> Map.get("filter", %{})
      |> then(&Map.merge(default_filters(), &1))

    socket =
      socket
      |> assign(:filters, filter_params)
      |> assign(:form, to_form(filter_params, as: :filter))
      |> assign(:cursor, nil)
      |> assign(
        :pending,
        visible_pending(%{
          filters: filter_params,
          scope_member_ids: socket.assigns[:scope_member_ids]
        })
      )
      |> assign(
        :top_models,
        top_models_card(%{
          filters: filter_params,
          scope_member_ids: socket.assigns[:scope_member_ids]
        })
      )
      |> assign(
        :top_users,
        top_users_card(%{
          filters: filter_params,
          scope_member_ids: socket.assigns[:scope_member_ids]
        })
      )

    {:noreply, load_logs_with_pending(socket, :reset)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns[:has_more] do
      {:noreply, load_logs(socket, :more)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reactivate_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    if cred.status == "error" do
      case Providers.reactivate_credential(cred) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Credencial reactivada.")
           |> load_alert_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo reactivar la credencial.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Solo se pueden reactivar credenciales en error.")}
    end
  end

  def handle_event("reset_breaker", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    Tokengate.Routing.CircuitBreakerManager.reset(cred.id)

    {:noreply,
     socket
     |> put_flash(:info, "Circuit breaker reseteado.")
     |> load_alert_data()}
  end

  ## Alert data loading ------------------------------------------------------

  defp load_alert_data(socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    credentials =
      from(c in Providers.Credential,
        join: p in assoc(c, :provider),
        where: c.status == "error",
        preload: [provider: p],
        order_by: [desc: c.error_at]
      )
      |> Repo.all()

    open = Tokengate.Routing.CircuitBreakerManager.open_breakers()
    open_ids = Map.keys(open)

    open_creds =
      if open_ids == [] do
        []
      else
        from(c in Providers.Credential,
          join: p in assoc(c, :provider),
          where: c.id in ^open_ids,
          preload: [provider: p]
        )
        |> Repo.all()
      end

    creds_by_id = Map.new(open_creds, &{&1.id, &1})

    breaker_alerts =
      Enum.flat_map(open, fn {cred_id, details} ->
        case creds_by_id do
          %{^cred_id => cred} -> [{cred, details}]
          _ -> []
        end
      end)

    since = DateTime.utc_now() |> DateTime.add(-24 * 3600, :second)

    cred_error_counts =
      from(rl in RequestLog,
        where: rl.status_code >= 400 and rl.inserted_at >= ^since,
        group_by: [rl.api_key_prefix, rl.provider_id],
        select: %{
          api_key_prefix: rl.api_key_prefix,
          provider_id: rl.provider_id,
          count: count(rl.id)
        }
      )
      |> Repo.all()

    socket
    |> assign(:error_credentials, credentials)
    |> assign(:breaker_alerts, breaker_alerts)
    |> assign(:cred_error_counts, cred_error_counts)
    |> assign(:budget_exhausted, Tokengate.Budgets.list_exhausted_member_budgets(timezone))
    |> assign(:budget_activity, load_budget_activity(timezone))
  end

  defp load_budget_activity(timezone) do
    today_start = Tokengate.Periods.start_of_day_utc(timezone)

    activity_query =
      from(rl in RequestLog,
        where: rl.inserted_at >= ^today_start,
        group_by: rl.team_member_id,
        select: %{
          team_member_id: rl.team_member_id,
          requests_today: count(rl.id),
          last_request: max(rl.inserted_at)
        }
      )

    top_provider_query =
      from(rl in RequestLog,
        where: rl.inserted_at >= ^today_start and not is_nil(rl.provider_id),
        group_by: [rl.team_member_id, rl.provider_id],
        select: %{
          team_member_id: rl.team_member_id,
          provider_id: rl.provider_id,
          request_count: count(rl.id)
        }
      )

    activity_data = Repo.all(activity_query) |> Map.new(fn a -> {a.team_member_id, a} end)

    top_providers =
      Repo.all(top_provider_query)
      |> Enum.group_by(fn t -> t.team_member_id end)
      |> Map.new(fn {member_id, providers} ->
        top = Enum.max_by(providers, fn p -> p.request_count end)
        {member_id, top.provider_id}
      end)

    provider_names =
      from(p in Providers.Provider, select: p)
      |> Repo.all()
      |> Map.new(fn p -> {p.id, p.name} end)

    activity_data
    |> Map.new(fn {member_id, activity} ->
      top_provider_id = Map.get(top_providers, member_id)
      top_provider_name = if top_provider_id, do: Map.get(provider_names, top_provider_id, "—")

      {member_id,
       %{
         requests_today: activity.requests_today,
         last_request: activity.last_request,
         top_provider: top_provider_name
       }}
    end)
  end

  defp errors_for_credential(cred, error_counts) do
    prefix = api_key_prefix(cred.api_key_encrypted)
    provider_id = cred.provider_id

    error_counts
    |> Enum.filter(fn ec ->
      ec.api_key_prefix == prefix && ec.provider_id == provider_id
    end)
    |> Enum.map(& &1.count)
    |> Enum.sum()
  end

  ## Template helpers ------------------------------------------------------

  defp format_cost(%Decimal{} = d) do
    d
    |> Decimal.to_float()
    |> then(&:erlang.float_to_binary(&1, [:compact, {:decimals, 6}]))
  end

  defp format_cost(nil), do: "—"

  defp format_number(n) when is_integer(n) do
    digits = Integer.to_string(abs(n))

    grouped =
      digits
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    if n < 0, do: "-" <> grouped, else: grouped
  end

  defp format_number(_), do: "0"

  ## System monitor formatters -------------------------------------------------

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_024 do
    "#{Float.round(bytes / 1_024, 1)} KB"
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "—"

  defp format_uptime(ms) when is_integer(ms) do
    total_seconds = div(ms, 1000)
    days = div(total_seconds, 86_400)
    hours = div(rem(total_seconds, 86_400), 3600)
    minutes = div(rem(total_seconds, 3600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  defp format_uptime(_), do: "—"

  defp format_query_ms(nil), do: "—"
  defp format_query_ms(ms) when is_integer(ms), do: "#{ms} ms"

  # CPU load: run_queue vs online schedulers. >1 means the VM is saturated
  # (more runnable work than scheduler capacity). Rendered as a percentage.
  defp cpu_load_pct(run_queue, schedulers_online)
       when is_integer(run_queue) and is_integer(schedulers_online) and schedulers_online > 0 do
    min(round(run_queue / schedulers_online * 100), 999)
  end

  defp cpu_load_pct(_, _), do: 0

  defp cpu_color(pct) when pct < 50, do: "text-success"
  defp cpu_color(pct) when pct < 90, do: "text-warning"
  defp cpu_color(_), do: "text-error"

  defp format_cache_tokens(read, creation)
       when read in [nil, 0] and creation in [nil, 0],
       do: "—"

  defp format_cache_tokens(read, creation) do
    "#{format_number(read || 0)} / #{format_number(creation || 0)}"
  end

  defp model_display(model_requested, model_responded) do
    if model_requested == model_responded do
      model_requested
    else
      "#{model_requested} → #{model_responded}"
    end
  end

  defp tps(completion_tokens, latency_ms)
       when is_integer(completion_tokens) and is_integer(latency_ms) and latency_ms > 0 do
    tps = completion_tokens / (latency_ms / 1000)
    :erlang.float_to_binary(tps, [:compact, {:decimals, 1}])
  end

  defp tps(_completion_tokens, _latency_ms), do: "—"

  # Time-to-first-token: only recorded for streaming requests (nil otherwise).
  defp format_ttft(nil), do: "—"
  defp format_ttft(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  defp format_ttft(ms) when is_integer(ms) do
    :erlang.float_to_binary(ms / 1000, [:compact, {:decimals, 1}]) <> "s"
  end

  defp status_badge_class(status_code) when status_code >= 200 and status_code < 300,
    do: "badge-success"

  defp status_badge_class(status_code) when status_code >= 400 and status_code < 500,
    do: "badge-warning"

  defp status_badge_class(status_code) when status_code >= 500, do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"

  defp member_email(%{team_member: %{user: %{email: email}}}), do: email
  defp member_email(_), do: "—"

  defp member_team(%{team_member: %{team: %{name: name}}}), do: name
  defp member_team(_), do: "—"

  defp provider_name(%{provider: %{name: name}}), do: name
  defp provider_name(_), do: "—"

  defp prov_key_display(%{credential_name: name, provider_key_prefix: prefix})
       when is_binary(name) and name != "" and is_binary(prefix) and prefix != "",
       do: "#{name} · #{prefix}"

  defp prov_key_display(%{credential_name: name})
       when is_binary(name) and name != "",
       do: name

  defp prov_key_display(%{provider_key_prefix: prefix})
       when is_binary(prefix) and prefix != "",
       do: prefix

  defp prov_key_display(_), do: "—"

  # --- Alert helpers ---------------------------------------------------------

  defp fmt_money(nil), do: "—"

  defp fmt_money(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  defp budget_periods(%{monthly_exhausted?: true}), do: "mensual"
  defp budget_periods(_), do: "—"

  defp breaker_label(:closed), do: "Cerrado"
  defp breaker_label(:open), do: "Abierto"
  defp breaker_label(:half_open), do: "Half-Open"
  defp breaker_label(_), do: "—"

  defp reason_label(nil), do: "—"
  defp reason_label(:server_error), do: "Error servidor"
  defp reason_label(:timeout), do: "Timeout"
  defp reason_label(:rate_limited), do: "Rate limited"
  defp reason_label(:auth_error), do: "Error auth"
  defp reason_label(:client_error), do: "Error cliente"
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(reason) when is_binary(reason), do: reason

  defp api_key_prefix(nil), do: "—"

  defp api_key_prefix(encrypted) when is_binary(encrypted) and byte_size(encrypted) > 8 do
    String.slice(encrypted, 0, 8) <> "…"
  end

  defp api_key_prefix(encrypted), do: encrypted

  defp fmt_duration(nil), do: "—"

  defp fmt_duration(%DateTime{} = opened_at) do
    diff = DateTime.diff(DateTime.utc_now(), opened_at, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      diff < 86_400 -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
      true -> "#{div(diff, 86_400)}d #{div(rem(diff, 86_400), 3600)}h"
    end
  end

  attr :value, :boolean, default: false

  defp think_badge(assigns) do
    ~H"""
    <span :if={@value} class="badge badge-sm badge-info">✓</span>
    <span :if={!@value} class="text-base-content/30">—</span>
    """
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Logs
          <:subtitle>Registro de solicitudes a la API en tiempo real</:subtitle>
        </.header>

        <%!-- Alert KPIs: creds en error, breakers, miembros sin crédito --%>
        <div
          :if={
            @is_admin and
              (@error_credentials != [] or @breaker_alerts != [] or @budget_exhausted != [])
          }
          class="grid grid-cols-1 sm:grid-cols-3 gap-4"
        >
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Credenciales en error
                </p>
                <.icon name="hero-exclamation-circle" class="w-4 h-4 text-error" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="alert-count-creds">
                {length(@error_credentials)}
              </p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Breakers abiertos
                </p>
                <.icon name="hero-shield-exclamation" class="w-4 h-4 text-warning" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="alert-count-breakers">
                {length(@breaker_alerts)}
              </p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Miembros sin crédito
                </p>
                <.icon name="hero-banknotes" class="w-4 h-4 text-error" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="alert-count-budgets">
                {length(@budget_exhausted)}
              </p>
            </div>
          </div>
        </div>

        <%!-- Alert tables: creds, breakers, budgets --%>
        <div :if={@is_admin} class="space-y-6">
          <%!-- Credentials in error --%>
          <div :if={@error_credentials != []} class="space-y-2">
            <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
              Credenciales deshabilitadas por error
            </h3>
            <div class="card bg-base-100 border border-error/30 shadow-sm">
              <div class="card-body p-0">
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Proveedor</th>
                        <th>Alias</th>
                        <th>API Key</th>
                        <th>Endpoint</th>
                        <th>Razón</th>
                        <th>Error</th>
                        <th>Cuándo</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={cred <- @error_credentials} id={"alert-cred-#{cred.id}"}>
                        <td class="font-medium">{cred.provider.name}</td>
                        <td>{cred.name || "—"}</td>
                        <td class="font-mono text-xs">{api_key_prefix(cred.api_key_encrypted)}</td>
                        <td
                          class="text-xs text-base-content/70 max-w-[200px] truncate"
                          title={cred.provider.base_url}
                        >
                          {cred.provider.base_url}
                        </td>
                        <td>
                          <code class="text-xs text-error">{cred.error_reason || "auth_error"}</code>
                        </td>
                        <td class="text-xs text-base-content/70 max-w-xs">
                          <span
                            :if={cred.error_message}
                            class="line-clamp-2"
                            title={cred.error_message}
                          >
                            {cred.error_message}
                          </span>
                          <span :if={!cred.error_message} class="text-base-content/30">—</span>
                        </td>
                        <td class="text-xs text-base-content/50">
                          {format_datetime(cred.error_at, @timezone)}
                        </td>
                        <td class="text-right">
                          <button
                            phx-click="reactivate_credential"
                            phx-value-id={cred.id}
                            class="btn btn-xs btn-warning"
                            id={"alert-reactivate-#{cred.id}"}
                          >
                            <.icon name="hero-arrow-path" class="w-3 h-3" /> Reactivar
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </div>

          <%!-- Open circuit breakers --%>
          <div :if={@breaker_alerts != []} class="space-y-2">
            <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
              Circuit breakers abiertos
            </h3>
            <div class="card bg-base-100 border border-warning/30 shadow-sm">
              <div class="card-body p-0">
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Proveedor</th>
                        <th>Alias</th>
                        <th>API Key</th>
                        <th>Estado</th>
                        <th>Razón</th>
                        <th>Detalle</th>
                        <th>Fallos</th>
                        <th>Abierto desde</th>
                        <th>Errores 24h</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={{cred, details} <- @breaker_alerts} id={"alert-breaker-#{cred.id}"}>
                        <td class="font-medium">{cred.provider.name}</td>
                        <td>{cred.name || "—"}</td>
                        <td class="font-mono text-xs">{api_key_prefix(cred.api_key_encrypted)}</td>
                        <td>
                          <span class={[
                            "badge badge-sm",
                            details.state == :open && "badge-error",
                            details.state == :half_open && "badge-warning"
                          ]}>
                            {breaker_label(details.state)}
                          </span>
                        </td>
                        <td class="text-sm">{reason_label(details.last_reason)}</td>
                        <td
                          class="text-xs text-base-content/70 max-w-[260px] truncate"
                          title={details.last_error_message}
                        >
                          {details.last_error_message || "—"}
                        </td>
                        <td class="text-sm tabular-nums">{details.failures}</td>
                        <td class="text-sm">{fmt_duration(details.opened_at)}</td>
                        <td class="text-sm tabular-nums">
                          {errors_for_credential(cred, @cred_error_counts)}
                        </td>
                        <td class="text-right">
                          <button
                            phx-click="reset_breaker"
                            phx-value-id={cred.id}
                            class="btn btn-xs btn-ghost"
                            id={"alert-reset-breaker-#{cred.id}"}
                          >
                            <.icon name="hero-arrow-path" class="w-3 h-3" /> Reset breaker
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </div>

          <%!-- Members out of budget --%>
          <div :if={@budget_exhausted != []} class="space-y-2">
            <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
              Miembros sin crédito
            </h3>
            <div class="card bg-base-100 border border-error/30 shadow-sm">
              <div class="card-body p-0">
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Usuario</th>
                        <th>Equipo</th>
                        <th>Límite agotado</th>
                        <th>Gasto mes</th>
                        <th>Gasto hoy</th>
                        <th>Requests hoy</th>
                        <th>Proveedor top (hoy)</th>
                        <th>Último request</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={b <- @budget_exhausted} id={"alert-budget-#{b.member.id}"}>
                        <td class="font-medium">{b.member.user.email}</td>
                        <td>{b.member.team.name}</td>
                        <td>
                          <span class="badge badge-sm badge-error">
                            {budget_periods(b)}
                          </span>
                        </td>
                        <td class="font-mono text-xs">
                          ${fmt_money(b.monthly_spend_usd)}
                          <span :if={b.monthly_limit_usd} class="text-base-content/50">
                            / ${fmt_money(b.monthly_limit_usd)}
                          </span>
                        </td>
                        <td class="font-mono text-xs">
                          ${fmt_money(b.daily_spend_usd)}
                        </td>
                        <td class="text-sm tabular-nums">
                          {Map.get(@budget_activity, b.member.id, %{}) |> Map.get(:requests_today, 0)}
                        </td>
                        <td class="text-sm">
                          {Map.get(@budget_activity, b.member.id, %{}) |> Map.get(:top_provider, "—")}
                        </td>
                        <td class="text-xs text-base-content/50">
                          {Map.get(@budget_activity, b.member.id, %{})
                          |> Map.get(:last_request)
                          |> format_datetime(@timezone)}
                        </td>
                        <td class="text-right">
                          <.link
                            navigate={~p"/dashboard/credits"}
                            class="btn btn-xs btn-ghost"
                            id={"alert-budget-credits-#{b.member.id}"}
                          >
                            Ver créditos
                          </.link>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- System monitor: live VM + DB health (admin only) --%>
        <div :if={@is_admin} class="space-y-2" id="system-monitor">
          <div class="flex items-center gap-2">
            <h3 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
              Monitor del sistema
            </h3>
            <span class="relative flex h-2 w-2">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-info opacity-60"></span>
              <span class="relative inline-flex rounded-full h-2 w-2 bg-info"></span>
            </span>
            <span class="text-xs text-base-content/40">en vivo · cada 2s</span>
          </div>

          <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">
            <%!-- RAM --%>
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="mon-ram">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">RAM</p>
                  <.icon name="hero-server-stack" class="w-4 h-4 text-base-content/40" />
                </div>
                <p class="mt-1 text-xl font-bold text-base-content">
                  {format_bytes(@system_metrics.memory.total)}
                </p>
                <p class="text-xs text-base-content/50">
                  proc {format_bytes(@system_metrics.memory.processes)} · ets {format_bytes(
                    @system_metrics.memory.ets
                  )}
                </p>
              </div>
            </div>

            <%!-- CPU / load --%>
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="mon-cpu">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                    Carga
                  </p>
                  <.icon name="hero-cpu-chip" class="w-4 h-4 text-base-content/40" />
                </div>
                <p class={[
                  "mt-1 text-xl font-bold",
                  cpu_color(
                    cpu_load_pct(@system_metrics.run_queue, @system_metrics.schedulers_online)
                  )
                ]}>
                  {cpu_load_pct(@system_metrics.run_queue, @system_metrics.schedulers_online)}%
                </p>
                <p class="text-xs text-base-content/50">
                  cola {@system_metrics.run_queue} · {@system_metrics.schedulers_online} sched
                </p>
              </div>
            </div>

            <%!-- Processes --%>
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="mon-processes">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                    Procesos
                  </p>
                  <.icon name="hero-squares-2x2" class="w-4 h-4 text-base-content/40" />
                </div>
                <p class="mt-1 text-xl font-bold text-base-content">
                  {format_number(@system_metrics.process_count)}
                </p>
                <p class="text-xs text-base-content/50">
                  límite {format_number(@system_metrics.process_limit)}
                </p>
              </div>
            </div>

            <%!-- DB --%>
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="mon-db">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                    Base de datos
                  </p>
                  <.icon name="hero-circle-stack" class="w-4 h-4 text-base-content/40" />
                </div>
                <p class="mt-1 text-xl font-bold text-base-content">
                  {format_query_ms(@system_metrics.db_query_ms)}
                </p>
                <p class="text-xs text-base-content/50">
                  pool {@system_metrics.db_pool_size} · SELECT 1
                </p>
              </div>
            </div>

            <%!-- IO --%>
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="mon-io">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">I/O</p>
                  <.icon name="hero-arrow-path" class="w-4 h-4 text-base-content/40" />
                </div>
                <p class="mt-1 text-xl font-bold text-base-content">
                  {format_bytes(@system_metrics.io_in)}
                </p>
                <p class="text-xs text-base-content/50">
                  in · out {format_bytes(@system_metrics.io_out)}
                </p>
              </div>
            </div>

            <%!-- Uptime --%>
            <div class="card bg-base-100 border border-base-300 shadow-sm" id="mon-uptime">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                    Uptime
                  </p>
                  <.icon name="hero-clock" class="w-4 h-4 text-base-content/40" />
                </div>
                <p class="mt-1 text-xl font-bold text-base-content">
                  {format_uptime(@system_metrics.uptime_ms)}
                </p>
                <p class="text-xs text-base-content/50">
                  {@system_metrics.schedulers} schedulers
                </p>
              </div>
            </div>
          </div>
        </div>

        <%!-- KPI strip: live indicators + summary, 5 cards in a row --%>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4">
          <%!-- Merged: Conectados + En vuelo --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-indicators">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Actividad
                </p>
                <div class="flex items-center gap-2">
                  <span class="relative flex h-2.5 w-2.5">
                    <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-60"></span>
                    <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-success"></span>
                  </span>
                  <.icon name="hero-bolt" class="w-4 h-4 text-accent" />
                </div>
              </div>
              <div class="mt-1 space-y-1">
                <div class="flex items-center justify-between">
                  <p class="text-xs text-base-content/40">Conectados</p>
                  <p class="text-2xl font-bold text-base-content text-right" id="online-count">
                    {length(@online_users)}
                  </p>
                </div>
                <div class="flex items-center justify-between">
                  <p class="text-xs text-base-content/40">En vuelo</p>
                  <p class="text-2xl font-bold text-base-content text-right" id="inflight-count">
                    {@api_inflight}
                  </p>
                </div>
              </div>
            </div>
          </div>

          <%!-- Top 3 modelos último minuto --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm" id="top-models">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Top 3 modelos · último minuto
                </p>
                <.icon name="hero-cpu-chip" class="w-4 h-4 text-base-content/40" />
              </div>
              <div class="mt-1 space-y-1" id="top-models-list">
                <div :for={m <- @top_models} class="flex items-center justify-between text-xs">
                  <span class="font-medium text-base-content truncate">{m.model}</span>
                  <span class="text-base-content/50 shrink-0 font-semibold ml-2">{m.count}</span>
                </div>
                <p :if={@top_models == []} class="text-xs text-base-content/30">—</p>
              </div>
            </div>
          </div>

          <%!-- Top 3 usuarios último minuto --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm" id="top-users">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Top 3 usuarios · último minuto
                </p>
                <.icon name="hero-users" class="w-4 h-4 text-base-content/40" />
              </div>
              <div class="mt-1 space-y-1" id="top-users-list">
                <div :for={u <- @top_users} class="flex items-center justify-between text-xs">
                  <span class="font-medium text-base-content truncate">{u.user}</span>
                  <span class="text-base-content/50 shrink-0 font-semibold ml-2">{u.count}</span>
                </div>
                <p :if={@top_users == []} class="text-xs text-base-content/30">—</p>
              </div>
            </div>
          </div>

          <%!-- Rendimiento: req/min + latencia --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Rendimiento
                </p>
                <.icon name="hero-arrow-trending-up" class="w-4 h-4 text-base-content/40" />
              </div>
              <div class="mt-1 space-y-1">
                <div class="flex items-center justify-between">
                  <p class="text-xs text-base-content/40">Req/min</p>
                  <p class="text-2xl font-bold text-base-content text-right" id="summary-req-per-min">
                    {@summary.req_per_min}
                  </p>
                </div>
                <div class="flex items-center justify-between">
                  <p class="text-xs text-base-content/40">Latencia prom</p>
                  <p class="text-2xl font-bold text-base-content text-right" id="summary-latency">
                    {if @summary.avg_latency_ms, do: "#{@summary.avg_latency_ms} ms", else: "—"}
                  </p>
                </div>
              </div>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Errores
                </p>
                <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-base-content/40" />
              </div>
              <div class="mt-1 space-y-1">
                <div class="flex items-center justify-between">
                  <p class="text-xs text-base-content/40">Errores</p>
                  <p
                    class={[
                      "text-2xl font-bold text-right",
                      if(@summary.error_count > 0, do: "text-error", else: "text-base-content")
                    ]}
                    id="summary-errors"
                  >
                    {@summary.error_count}
                  </p>
                </div>
                <div class="flex items-center justify-between">
                  <p class="text-xs text-base-content/40">Tasa</p>
                  <p class="text-2xl font-bold text-base-content text-right" id="summary-error-rate">
                    {@summary.error_rate}%
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Filter form --%>
        <.form
          for={@form}
          id="logs-filter-form"
          phx-change="filter"
          class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-7 gap-3"
        >
          <.input
            field={@form[:status_class]}
            type="select"
            prompt="Todos"
            options={[{"2xx", "2xx"}, {"4xx", "4xx"}, {"5xx", "5xx"}]}
            label="Estado"
          />
          <.input
            field={@form[:streaming]}
            type="select"
            prompt="Todos"
            options={[{"Sí", "true"}, {"No", "false"}]}
            label="Streaming"
          />
          <.input
            field={@form[:model_search]}
            type="select"
            prompt="Todos"
            options={@model_options}
            label="Modelo"
          />
          <.input
            field={@form[:team_id]}
            type="select"
            prompt="Todos"
            options={@team_options}
            label="Equipo"
          />
          <.input
            field={@form[:error_reason]}
            type="select"
            prompt="Todos"
            options={[
              {"rate_limited", "rate_limited"},
              {"timeout", "timeout"},
              {"server_error", "server_error"},
              {"auth_error", "auth_error"},
              {"client_error", "client_error"}
            ]}
            label="Error"
          />
          <.input
            field={@form[:from]}
            type="date"
            label="Desde"
          />
          <.input
            field={@form[:to]}
            type="date"
            label="Hasta"
          />
        </.form>

        <div class="flex justify-end">
          <.link
            href="/dashboard/stats/export?type=errors"
            class="btn btn-sm btn-ghost"
            id="csv-errors"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV Errores
          </.link>
        </div>

        <%!-- Logs table (includes pending in-flight rows highlighted) --%>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr class="border-b-0">
                <th
                  colspan="6"
                  class="text-[10px] uppercase tracking-wider text-primary/70 bg-primary/5 border-r border-base-200"
                >
                  Cliente
                </th>
                <th
                  colspan="5"
                  class="text-[10px] uppercase tracking-wider text-warning/70 bg-warning/5 border-r border-base-200"
                >
                  Proveedor
                </th>
                <th
                  colspan="5"
                  class="text-[10px] uppercase tracking-wider text-accent/70 bg-accent/5 border-r border-base-200"
                >
                  Respuesta
                </th>
                <th
                  colspan="5"
                  class="text-[10px] uppercase tracking-wider text-info/70 bg-info/5 border-r border-base-200"
                >
                  Rendimiento
                </th>
                <th
                  colspan="4"
                  class="text-[10px] uppercase tracking-wider text-success/70 bg-success/5"
                >
                  Costos
                </th>
              </tr>
              <tr>
                <th>Fecha</th>
                <th>Modelo</th>
                <th>Usuario</th>
                <th>Equipo</th>
                <th>Agente</th>
                <th>API Key</th>
                <th class="border-r border-base-200">Proveedor</th>
                <th title="API key o alias del proveedor">Prov. Key</th>
                <th title="Código HTTP del proveedor">Prov. Status</th>
                <th
                  title="Razón del error del proveedor"
                  colspan="2"
                  class="border-r border-base-200"
                >
                  Error
                </th>
                <th title="Código HTTP enviado al cliente">Estado</th>
                <th>Think</th>
                <th>Effort</th>
                <th class="border-r border-base-200">Streaming</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right" title="Cache read / Cache creation">Cache R/C</th>
                <th class="text-right">TPS</th>
                <th title="Time to first token — solo streaming">TTFT</th>
                <th class="border-r border-base-200">Latencia</th>
                <th class="text-right">Costo</th>
              </tr>
            </thead>
            <tbody id="logs" phx-update="stream">
              <tr id="logs-empty" class="hidden only:table-row">
                <td colspan="25" class="text-center py-8 text-base-content/40">
                  No hay logs que coincidan con los filtros.
                </td>
              </tr>
              <tr
                :for={{id, log} <- @streams.logs}
                id={id}
                class={if Map.get(log, :__pending__), do: "bg-warning/20 hover:bg-warning/30"}
              >
                <%= if Map.get(log, :__pending__) do %>
                  <%!-- Pending in-flight row --%>
                  <td class="whitespace-nowrap text-sm font-medium">
                    <span class="flex items-center gap-1.5">
                      <span class="relative flex h-2 w-2">
                        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-warning opacity-60"></span>
                        <span class="relative inline-flex rounded-full h-2 w-2 bg-warning"></span>
                      </span>
                      {format_datetime(log.inserted_at, @timezone)}
                    </span>
                  </td>
                  <td class="text-sm">{log.model_requested}</td>
                  <td class="text-sm">{member_email(log)}</td>
                  <td class="text-sm">{member_team(log)}</td>
                  <td class="text-sm">{log.client_agent || "—"}</td>
                  <td class="text-sm">{log.api_key_prefix || "—"}</td>
                  <td class="text-sm border-r border-base-200">{provider_name(log)}</td>
                  <td class="text-sm">{prov_key_display(log)}</td>
                  <td class="text-sm">—</td>
                  <td colspan="2" class="text-sm border-r border-base-200">—</td>
                  <td>
                    <span class="badge badge-sm badge-warning">En vuelo</span>
                  </td>
                  <td><.think_badge value={log.think} /></td>
                  <td class="text-sm">{log.effort || "—"}</td>
                  <td class="text-sm border-r border-base-200">
                    {if log.streaming, do: "Sí", else: "No"}
                  </td>
                  <td class="text-sm text-right tabular-nums">—</td>
                  <td class="text-sm text-right tabular-nums">—</td>
                  <td class="text-sm text-right tabular-nums">—</td>
                  <td class="text-sm text-right tabular-nums text-base-content/70">—</td>
                  <td class="text-sm text-base-content/70">—</td>
                  <td class="text-sm border-r border-base-200">—</td>
                  <td class="text-sm text-right tabular-nums">—</td>
                <% else %>
                  <%!-- Completed log row --%>
                  <td class="whitespace-nowrap text-sm">
                    {format_datetime(log.inserted_at, @timezone)}
                  </td>
                  <td class="text-sm">{model_display(log.model_requested, log.model_responded)}</td>
                  <td class="text-sm">{member_email(log)}</td>
                  <td class="text-sm">{member_team(log)}</td>
                  <td class="text-sm" title={log.agent_type}>
                    {log.client_agent || "—"}
                  </td>
                  <td class="text-sm">{log.api_key_prefix || "—"}</td>
                  <td class="text-sm border-r border-base-200">{provider_name(log)}</td>
                  <td
                    class="text-sm"
                    title={
                      if log.credential_name && log.credential_name != "",
                        do: log.credential_name,
                        else: nil
                    }
                  >
                    {prov_key_display(log)}
                  </td>
                  <td class="text-sm">
                    <span :if={log.provider_status_code} class="badge badge-sm badge-ghost">{log.provider_status_code}</span>
                    <span :if={!log.provider_status_code} class="text-base-content/40">—</span>
                  </td>
                  <td colspan="2" class="text-sm border-r border-base-200">
                    <div :if={log.error_reason} class="flex flex-col gap-0.5">
                      <span class="badge badge-sm badge-error">{log.error_reason}</span>
                      <span
                        :if={log.error_message}
                        class="text-xs text-base-content/60 max-w-[220px] truncate"
                        title={log.error_message}
                      >
                        {log.error_message}
                      </span>
                    </div>
                    <span :if={!log.error_reason} class="text-base-content/40">—</span>
                  </td>
                  <td>
                    <span class={["badge", "badge-sm", status_badge_class(log.status_code)]}>
                      {log.status_code}
                    </span>
                    <span
                      :if={log.status_code == 200 && log.error_reason}
                      class="badge badge-sm badge-warning ml-1"
                      title="El proveedor falló y la request fue recuperada por fallback a otro proveedor"
                    >
                      fallback
                    </span>
                  </td>
                  <td><.think_badge value={log.think} /></td>
                  <td class="text-sm">{log.effort || "—"}</td>
                  <td class="text-sm border-r border-base-200">
                    {if log.streaming, do: "Sí", else: "No"}
                  </td>
                  <td class="text-sm text-right tabular-nums">{format_number(log.prompt_tokens)}</td>
                  <td class="text-sm text-right tabular-nums">
                    {format_number(log.completion_tokens)}
                  </td>
                  <td class="text-sm text-right tabular-nums">
                    {format_cache_tokens(log.cache_read_tokens, log.cache_creation_tokens)}
                  </td>
                  <td class="text-sm text-right tabular-nums text-base-content/70">
                    {tps(log.completion_tokens, log.latency_ms)}
                  </td>
                  <td class="text-sm text-base-content/70">{format_ttft(log.ttft_ms)}</td>
                  <td class="text-sm border-r border-base-200">{log.latency_ms}ms</td>
                  <td class="text-sm text-right tabular-nums">
                    {format_cost(log.provider_cost_usd)}
                  </td>
                <% end %>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Load more --%>
        <div class="flex justify-center">
          <button
            :if={@has_more}
            phx-click="load_more"
            class="btn btn-primary btn-sm"
            id="load-more-btn"
          >
            <.icon name="hero-chevron-down" class="w-4 h-4" /> Cargar más
          </button>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
