defmodule TokengateWeb.LogsLive do
  @moduledoc false
  use TokengateWeb, :live_view

  alias Tokengate.{Accounts, Logs}
  alias Tokengate.Limits.Manager, as: Limits
  alias Tokengate.Logs.Inflight
  alias Tokengate.Providers

  @page_size 50
  @pubsub Tokengate.PubSub
  @logs_topic "logs:new"
  @summary_refresh_interval_ms 2_000
  @summary_tick_interval_ms 5_000
  @inflight_refresh_interval_ms 3_000

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
      |> assign(:summary_refresh_scheduled, false)
      |> assign(:last_seen_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> assign(:online_users, [])
      |> assign(:api_inflight, 0)
      |> assign(:pending, [])
      |> assign(:model_options, model_options())
      |> assign(:team_options, team_options())
      |> assign(:is_admin, user.global_role == "admin")
      |> require_admin_hook()

    socket = load_logs(socket, :reset)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @logs_topic)
      Phoenix.PubSub.subscribe(@pubsub, Inflight.topic())
      Phoenix.PubSub.subscribe(@pubsub, TokengateWeb.Presence.topic())

      send(self(), :refresh_inflight)

      # Rolling-window KPIs decay with time (req/min drops even when no new
      # logs arrive), so refresh them on a fixed tick, not only on new logs.
      :timer.send_interval(@summary_tick_interval_ms, :refresh_summary)

      {:ok,
       socket
       |> assign(:online_users, TokengateWeb.Presence.list_online())
       |> assign(:api_inflight, Limits.total_inflight())
       |> assign(:pending, visible_pending(socket.assigns))}
    else
      {:ok, socket}
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
    {:noreply, assign(socket, :api_inflight, Limits.total_inflight())}
  end

  def handle_info({:inflight_started, entry}, socket) do
    if pending_visible?(entry, socket.assigns) do
      {:noreply, assign(socket, :pending, [entry | socket.assigns[:pending]])}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:inflight_done, id}, socket) do
    pending = Enum.reject(socket.assigns[:pending], &(&1.id == id))
    {:noreply, assign(socket, :pending, pending)}
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

    agent in ["", nil, log.agent_type] and
      status_class_match?(log.status_code, status_class) and
      streaming_match?(log.streaming, streaming) and
      model_match?(log, model_search) and
      team_id_match?(log, team_id) and
      date_range_match?(log.inserted_at, filters["from"], filters["to"], timezone)
  end

  defp team_id_match?(_log, ""), do: true
  defp team_id_match?(_log, nil), do: true

  defp team_id_match?(log, team_id) do
    log.team_member && log.team_member.team && log.team_member.team.id == team_id
  end

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
      "team_id" => ""
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

    {:noreply, load_logs(socket, :reset)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns[:has_more] do
      {:noreply, load_logs(socket, :more)}
    else
      {:noreply, socket}
    end
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

  defp format_cache_tokens(read, creation)
       when read in [nil, 0] and creation in [nil, 0],
       do: "—"

  defp format_cache_tokens(read, creation) do
    "#{format_number(read || 0)} / #{format_number(creation || 0)}"
  end

  defp initials(email) when is_binary(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.split(~r/[._-]/)
    |> Enum.filter(&(&1 != ""))
    |> Enum.take(2)
    |> Enum.map_join("", &String.first(&1))
    |> String.upcase()
  end

  defp initials(_), do: "?"

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

        <%!-- KPI strip: live indicators + summary, 5 cards in a row --%>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-4">
          <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-indicators">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Conectados
                </p>
                <span class="relative flex h-2.5 w-2.5">
                  <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-60"></span>
                  <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-success"></span>
                </span>
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="online-count">
                {length(@online_users)}
              </p>
              <div class="flex -space-x-2 mt-1 min-h-7" id="online-users">
                <span
                  :for={u <- @online_users}
                  class="inline-flex items-center justify-center w-7 h-7 rounded-full bg-primary/15 text-primary text-xs font-semibold ring-2 ring-base-100"
                  title={u.email}
                  id={"online-#{u.id}"}
                >
                  {initials(u.email)}
                </span>
              </div>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm" id="inflight-indicator">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  En vuelo
                </p>
                <.icon name="hero-bolt" class="w-4 h-4 text-accent" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="inflight-count">
                {@api_inflight}
              </p>
              <p class="text-xs text-base-content/40 mt-1">requests en proceso</p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Req/min
                </p>
                <.icon name="hero-arrow-trending-up" class="w-4 h-4 text-base-content/40" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="summary-req-per-min">
                {@summary.req_per_min}
              </p>
              <p class="text-xs text-base-content/40 mt-1">últimos 5 min</p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Latencia prom
                </p>
                <.icon name="hero-clock" class="w-4 h-4 text-base-content/40" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="summary-latency">
                {if @summary.avg_latency_ms, do: "#{@summary.avg_latency_ms} ms", else: "—"}
              </p>
              <p class="text-xs text-base-content/40 mt-1">últimos 5 min</p>
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
              <p
                class={[
                  "mt-1 text-2xl font-bold",
                  if(@summary.error_count > 0, do: "text-error", else: "text-base-content")
                ]}
                id="summary-errors"
              >
                {@summary.error_count}
              </p>
              <p class="text-xs text-base-content/40 mt-1">
                {@summary.error_rate}% · últimos 5 min
              </p>
            </div>
          </div>
        </div>

        <%!-- Filter form --%>
        <.form
          for={@form}
          id="logs-filter-form"
          phx-change="filter"
          class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3"
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

        <%!-- Pending (in-flight) requests --%>
        <div
          :if={@pending != []}
          class="card bg-base-100 border border-warning/40 shadow-sm"
          id="pending-section"
        >
          <div class="card-body p-4">
            <div class="flex items-center gap-2 mb-2">
              <span class="relative flex h-2.5 w-2.5">
                <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-warning opacity-60"></span>
                <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-warning"></span>
              </span>
              <h3 class="text-sm font-semibold">En vuelo ahora ({length(@pending)})</h3>
            </div>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Inicio</th>
                    <th>Modelo</th>
                    <th>Usuario</th>
                    <th>Equipo</th>
                    <th>Agente</th>
                    <th>API Key</th>
                    <th>Proveedor</th>
                    <th>Credencial</th>
                    <th title="API key o alias del proveedor">Prov. Key</th>
                    <th>Think</th>
                    <th>Effort</th>
                    <th>Streaming</th>
                    <th>Estado</th>
                  </tr>
                </thead>
                <tbody id="pending-rows">
                  <tr :for={entry <- @pending} id={"pending-row-#{entry.id}"}>
                    <td class="whitespace-nowrap text-sm">
                      {format_datetime(entry.started_at, @timezone)}
                    </td>
                    <td class="text-sm">{entry.model_requested}</td>
                    <td class="text-sm">{entry.user_email || "—"}</td>
                    <td class="text-sm">{entry.team_name || "—"}</td>
                    <td class="text-sm">{entry.client_agent || "—"}</td>
                    <td class="text-sm">{entry.api_key_prefix || "—"}</td>
                    <td class="text-sm">{entry.provider_name || "—"}</td>
                    <td class="text-sm">{entry.credential_name || "—"}</td>
                    <td class="text-sm">{entry.credential_name || "—"}</td>
                    <td><.think_badge value={entry.think} /></td>
                    <td class="text-sm">{entry.effort || "—"}</td>
                    <td>{if entry.streaming, do: "Sí", else: "No"}</td>
                    <td><span class="badge badge-sm badge-warning">Pending</span></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <%!-- Logs table --%>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr class="border-b-0">
                <th
                  colspan="7"
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
                <th class="border-r border-base-200">Credencial</th>
                <th>Proveedor</th>
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
                <td colspan="26" class="text-center py-8 text-base-content/40">
                  No hay logs que coincidan con los filtros.
                </td>
              </tr>
              <tr :for={{id, log} <- @streams.logs} id={id}>
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
                <td class="text-sm border-r border-base-200">{log.credential_name || "—"}</td>
                <td class="text-sm">{provider_name(log)}</td>
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
                  <span :if={log.error_reason} class="badge badge-sm badge-error">{log.error_reason}</span>
                  <span :if={!log.error_reason} class="text-base-content/40">—</span>
                </td>
                <td>
                  <span class={["badge", "badge-sm", status_badge_class(log.status_code)]}>
                    {log.status_code}
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
                <td class="text-sm text-right tabular-nums">{format_cost(log.provider_cost_usd)}</td>
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
