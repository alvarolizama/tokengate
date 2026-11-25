defmodule TokengateWeb.MonitoringLive do
  @moduledoc false
  use TokengateWeb, :live_view
  import Ecto.Query, warn: false

  alias Tokengate.{Accounts, Logs, Repo}
  alias Tokengate.Accounts.ApiKey
  alias Tokengate.Logs.Inflight
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Providers

  @page_size 50
  # Hard cap on the rows the feed keeps in the DOM AND in the LiveView state.
  # A session left open used to accumulate every log of the deployment: the
  # socket, the stream state and the client DOM grew with uptime, not with
  # what the operator can look at. New arrivals push the oldest rows out.
  @max_stream_rows 500
  @pubsub Tokengate.PubSub
  @logs_topic "logs:new"
  @summary_refresh_interval_ms 2_000
  # El resumen vive en el DashboardCache global: el TTL tiene que sobrevivir
  # al tick (2s) para que los visores de una misma ventana compartan UN
  # cálculo; si caduca entre ticks, cada visor recalcula el suyo.
  @summary_cache_ttl_ms 2_500
  @inflight_refresh_interval_ms 3_000
  @top_card_cache_ms 3_500

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    scope_member_ids = resolve_scope_member_ids(user)

    socket =
      socket
      |> assign(:page_title, "Monitoring · Tokengate")
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
      |> assign(:pending, [])
      |> assign(:stream_rows, 0)
      |> assign(:model_options, model_options())
      |> assign(:group_options, group_options())
      |> assign(:api_key_options, api_key_options())
      |> assign(:is_admin, user.global_role == "admin")
      |> assign(:error_detail, nil)
      |> require_admin_hook()

    socket = load_logs(socket, :reset)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @logs_topic)
      Phoenix.PubSub.subscribe(@pubsub, Inflight.topic())

      send(self(), :refresh_inflight)

      pending = visible_pending(socket.assigns)

      socket =
        socket
        |> assign(:top_models, top_models_cached(socket.assigns))
        |> assign(:top_users, top_users_cached(socket.assigns))
        |> assign(:pending, pending)

      # Insert existing pending entries at the top of the logs stream
      socket =
        Enum.reduce(pending, socket, fn entry, acc ->
          prepend_log(acc, pending_entry_to_log(entry))
        end)

      {:ok, socket}
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
        {:halt, put_flash(socket, :error, gettext("Not authorized."))}
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
        |> prepend_log(log)
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

  def handle_info(:refresh_inflight, socket) do
    Process.send_after(self(), :refresh_inflight, @inflight_refresh_interval_ms)

    {:noreply,
     socket
     |> assign(:top_models, top_models_cached(socket.assigns))
     |> assign(:top_users, top_users_cached(socket.assigns))}
  end

  def handle_info({:inflight_started, entry}, socket) do
    if pending_visible?(entry, socket.assigns) do
      socket =
        socket
        |> assign(:pending, [entry | socket.assigns[:pending]])
        |> prepend_log(pending_entry_to_log(entry))

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
      |> stream_delete(:logs, %{id: "pending-#{id}"})

    socket =
      if removed? do
        assign(socket, :stream_rows, max((socket.assigns[:stream_rows] || 0) - 1, 0))
      else
        socket
      end

    {:noreply, socket}
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
    log.group_member_id in member_ids
  end

  defp log_matches_filters?(log, filters, timezone) do
    agent = filters["agent_type"]
    status_class = filters["status_class"]
    streaming = filters["streaming"]
    model_search = filters["model_search"]
    group_id = filters["group_id"]
    subject_type = filters["subject_type"]
    error_reason = filters["error_reason"]
    api_key_id = filters["api_key_id"]

    agent in ["", nil, log.agent_type] and
      status_class_match?(log.status_code, status_class) and
      streaming_match?(log.streaming, streaming) and
      model_match?(log, model_search) and
      group_id_match?(log, group_id) and
      subject_type_match?(log, subject_type) and
      error_reason_match?(log, error_reason) and
      api_key_match?(log, api_key_id) and
      date_range_match?(log.inserted_at, filters["from"], filters["to"], timezone)
  end

  defp api_key_match?(_log, ""), do: true
  defp api_key_match?(_log, nil), do: true
  defp api_key_match?(log, api_key_id), do: log.api_key_id == api_key_id

  defp group_id_match?(_log, ""), do: true
  defp group_id_match?(_log, nil), do: true

  defp group_id_match?(log, group_id) do
    log.group_member && log.group_member.group && log.group_member.group.id == group_id
  end

  defp subject_type_match?(_log, ""), do: true
  defp subject_type_match?(_log, nil), do: true
  defp subject_type_match?(log, subject_type), do: log.subject_type == subject_type

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

  # Top-cards: build a filter map that combines the user's scope
  # (group_member_ids) with the active UI filters so the cards never leak
  # rows the table would hide.
  defp top_card_filters(assigns) do
    filters = assigns[:filters] || %{}

    base =
      case assigns[:scope_member_ids] do
        nil -> %{}
        ids -> %{group_member_ids: ids}
      end

    base
    |> maybe_put_filter(filters, "agent_type", :agent_type)
    |> maybe_put_filter(filters, "model_search", :model_search)
    |> maybe_put_filter(filters, "group_id", :group_id)
    |> maybe_put_filter(filters, "streaming", :streaming)
    |> maybe_put_filter(filters, "error_reason", :error_reason)
    |> maybe_put_filter(filters, "api_key_id", :api_key_id)
    |> maybe_put_filter(filters, "status_class", :status_class)
    |> maybe_put_filter(filters, "subject_type", :subject_type)
    # Date bounds travel as the raw strings the form holds: `Logs` casts them
    # (and ignores what it cannot parse). Without them the cards ranked rows
    # the table was hiding.
    |> maybe_put_filter(filters, "from", :from)
    |> maybe_put_filter(filters, "to", :to)
  end

  defp maybe_put_filter(acc, filters, key, field) do
    case Map.get(filters, key) do
      nil -> acc
      "" -> acc
      value -> Map.put(acc, field, value)
    end
  end

  # Top-model / top-user cards se recalculan en cada :refresh_inflight (3s).
  # Antes había una caché POR VISOR en assigns: N monitores abiertos = N
  # cálculos por tick. Ahora la entrada vive en el DashboardCache global
  # (TTL 3.5s, clave = scope + filtros activos), así que el tick de cada
  # visor es solo el disparador que LEE el resultado compartido.
  defp top_models_cached(assigns) do
    filters = top_card_filters(assigns)

    DashboardCache.fetch_or_compute(
      {:monitoring_top_models, filters},
      fn -> Logs.top_models_last_minutes(1, 3, filters) end,
      ttl: @top_card_cache_ms
    )
  end

  defp top_users_cached(assigns) do
    filters = top_card_filters(assigns)

    DashboardCache.fetch_or_compute(
      {:monitoring_top_users, filters},
      fn -> Logs.top_users_last_minutes(1, 3, filters) end,
      ttl: @top_card_cache_ms
    )
  end

  # Converts an Inflight entry to the log shape so it renders inside the
  # main logs table. `__pending__: true` flags the row for special styling.
  defp pending_entry_to_log(entry) do
    %{
      id: "pending-#{entry.id}",
      inserted_at: entry.started_at,
      model_requested: entry.model_requested,
      model_responded: nil,
      subject_type: entry.subject_type,
      service: if(entry.service_name, do: %{name: entry.service_name}, else: nil),
      group_member: %{user: %{email: entry.user_email}, group: %{name: entry.group_name}},
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
        ids -> entry.group_member_id in ids
      end

    agent = filters["agent_type"]
    streaming = filters["streaming"]
    model_search = filters["model_search"]
    group_id = filters["group_id"]
    subject_type = filters["subject_type"]

    in_scope and
      agent in ["", nil, entry.agent_type] and
      streaming_match?(entry.streaming, streaming) and
      pending_model_match?(entry, model_search) and
      group_id in ["", nil, entry.group_id] and
      subject_type in ["", nil, entry.subject_type] and
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
    Providers.list_models()
    |> Enum.map(fn model_ -> {model_.name, model_.name} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp group_options do
    Accounts.list_groups()
    |> Enum.map(fn group -> {group.name, group.id} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # Options del selector desde la tabla `api_keys` (chica, indexada): el
  # `DISTINCT api_key_id` sobre toda `request_logs` se corría en CADA
  # phx-change de los filtros — un Parallel Seq Scan de ~10k buffers por
  # tecla. El selector ahora lista las keys activas (no solo las con
  # tráfico); una key revocada con logs viejos resuelve su label por el
  # prefijo histórico en `api_key_display/2`. Se carga una vez en mount.
  defp api_key_options do
    Repo.all(
      from ak in ApiKey,
        where: ak.status == "active",
        select: {ak.id, ak.label, ak.key_prefix}
    )
    |> Enum.map(fn {id, label, prefix} -> {label || prefix || id, id} end)
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

  defp parse_date_string(date_str, timezone, mode \\ :start_of_day) do
    TokengateWeb.TimezoneHelper.parse_local_date(date_str, timezone, mode)
  end

  defp max_datetime(dt1, dt2) do
    if DateTime.compare(dt1, dt2) == :gt, do: dt1, else: dt2
  end

  defp refresh_summary(socket) do
    socket |> assign(:summary, summary_for(socket))
  end

  # Every insert at the top of the feed goes through here: `limit:` makes
  # LiveView prune the OLDEST item server-side and emit its DOM delete, so the
  # stream state and the client DOM stay bounded by @max_stream_rows however
  # long the session lives.
  defp prepend_log(socket, log) do
    rows = socket.assigns[:stream_rows] || 0

    socket
    |> stream_insert(:logs, log, at: 0, limit: @max_stream_rows)
    |> assign(:stream_rows, min(rows + 1, @max_stream_rows))
  end

  # El resumen (ventana de 5 min con el scope/filtros del visor) se comparte
  # entre visores con la misma forma de filtros: N monitores = 1 cálculo por
  # ventana de TTL, no N. La clave lleva los filtros completos, así que dos
  # visores con scopes distintos nunca leen el mismo número.
  defp summary_for(socket) do
    filters = build_filters(socket, include_limit: false, include_cursor: false)

    DashboardCache.fetch_or_compute(
      {:monitoring_summary, filters},
      fn -> Logs.realtime_summary(filters) end,
      ttl: @summary_cache_ttl_ms
    )
  end

  ## Scope resolution ------------------------------------------------------

  defp resolve_scope_member_ids(%{global_role: "admin"}) do
    nil
  end

  defp resolve_scope_member_ids(user) do
    # Sorted: the list feeds cache keys (DashboardCache) and it must be
    # deterministic — two viewers with the same memberships must produce the
    # same key regardless of row return order.
    memberships = Accounts.list_group_members_for_user(user.id)
    memberships |> Enum.map(& &1.id) |> Enum.sort()
  end

  ## Data loading ----------------------------------------------------------

  defp load_logs_with_pending(socket, :reset) do
    socket = load_logs(socket, :reset)

    # Re-insert pending entries at the top after stream reset
    pending = socket.assigns[:pending] || []

    Enum.reduce(pending, socket, fn entry, acc ->
      prepend_log(acc, pending_entry_to_log(entry))
    end)
  end

  defp load_logs(socket, mode) do
    page_size = page_size_for(socket, mode)
    list_filters = build_filters(socket, include_cursor: mode == :more, limit: page_size)

    # `list_feed/1` bounds the window (F39): without it every filter change
    # walked the ~90 retained partitions until it collected a page.
    logs = Logs.list_feed(list_filters)

    summary = summary_for(socket)

    stream_rows =
      case mode do
        :reset -> length(logs)
        :more -> min((socket.assigns[:stream_rows] || 0) + length(logs), @max_stream_rows)
      end

    has_more =
      length(logs) == page_size and stream_rows < @max_stream_rows

    socket =
      socket
      |> assign(:summary, summary)
      |> assign(:has_more, has_more)
      |> assign(:stream_rows, stream_rows)

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
        # Tuple cursor: inserted_at is timestamp(0), so a bare timestamp drops
        # every row sharing the boundary second (same fix as user_stats_live
        # and service_stats_body).
        assign(socket, :cursor, {oldest.inserted_at, oldest.id})
    end
  end

  # Page the feed can still hold: "load more" never fetches past the cap, so
  # the stream cannot grow beyond @max_stream_rows through the UI either.
  defp page_size_for(_socket, :reset), do: @page_size

  defp page_size_for(socket, :more) do
    max(@max_stream_rows - (socket.assigns[:stream_rows] || 0), 0)
    |> min(@page_size)
  end

  ## Filter building -------------------------------------------------------

  defp default_filters do
    %{
      "status_class" => "",
      "streaming" => "",
      "from" => "",
      "to" => "",
      "model_search" => "",
      "group_id" => "",
      "subject_type" => "",
      "error_reason" => "",
      "api_key_id" => ""
    }
  end

  defp build_filters(socket, opts) do
    include_cursor = Keyword.get(opts, :include_cursor, false)
    include_limit = Keyword.get(opts, :include_limit, true)
    limit = Keyword.get(opts, :limit) || @page_size
    form_filters = socket.assigns[:filters]
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    base =
      %{}
      |> maybe_put(:status_class, form_filters["status_class"])
      |> maybe_put(:streaming, parse_bool(form_filters["streaming"]))
      |> maybe_put(:model_search, form_filters["model_search"])
      |> maybe_put_group_id(form_filters["group_id"])
      |> maybe_put(:subject_type, form_filters["subject_type"])
      |> maybe_put(:error_reason, form_filters["error_reason"])
      |> maybe_put(:api_key_id, form_filters["api_key_id"])
      |> maybe_put(:from, parse_from_date(form_filters["from"], timezone))
      |> maybe_put(:to, parse_to_date(form_filters["to"], timezone))
      |> maybe_put_scope(socket.assigns[:scope_member_ids])

    base =
      if include_cursor do
        maybe_put(base, :before, socket.assigns[:cursor])
      else
        base
      end

    if include_limit, do: Map.put(base, :limit, limit), else: base
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_group_id(map, ""), do: map
  defp maybe_put_group_id(map, nil), do: map
  defp maybe_put_group_id(map, group_id), do: Map.put(map, :group_id, group_id)

  defp maybe_put_scope(map, nil), do: map
  defp maybe_put_scope(map, ids), do: Map.put(map, :group_member_ids, ids)

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp parse_from_date(date_str, timezone) do
    TokengateWeb.TimezoneHelper.parse_local_date(date_str, timezone, :start_of_day)
  end

  defp parse_to_date(date_str, timezone) do
    TokengateWeb.TimezoneHelper.parse_local_date(date_str, timezone, :end_of_day)
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
          scope_member_ids: socket.assigns[:scope_member_ids],
          timezone: socket.assigns[:timezone] || "Etc/UTC"
        })
      )
      |> assign(
        :top_models,
        top_models_cached(%{
          filters: filter_params,
          scope_member_ids: socket.assigns[:scope_member_ids]
        })
      )
      |> assign(
        :top_users,
        top_users_cached(%{
          filters: filter_params,
          scope_member_ids: socket.assigns[:scope_member_ids]
        })
      )

    {:noreply, load_logs_with_pending(socket, :reset)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns[:has_more] and page_size_for(socket, :more) > 0 do
      {:noreply, load_logs(socket, :more)}
    else
      {:noreply, socket}
    end
  end

  # Error detail for one row: opens the modal with the upstream's full message
  # (truncated to 220px in the table) plus the request context. Read by PK
  # (`id` + `inserted_at`, the partition key the row carries) with the same
  # preloads as the table — it is a click, not a hot path, so the modal does
  # not depend on the row still being in the stream, and the lookup no longer
  # probes ~90 partitions (F49).
  def handle_event("show_error", %{"log-id" => log_id} = params, socket) do
    {:noreply, assign(socket, :error_detail, Logs.get_log(log_id, params["inserted-at"]))}
  end

  def handle_event("show_error", _params, socket), do: {:noreply, socket}

  def handle_event("close_error", _params, socket) do
    {:noreply, assign(socket, :error_detail, nil)}
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

  defp format_cache_tokens(nil), do: "—"
  defp format_cache_tokens(0), do: "—"
  defp format_cache_tokens(read), do: format_number(read)

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

  defp member_email(%{group_member: %{user: %{email: email}}}), do: email
  defp member_email(_), do: "—"

  # The "Usuario" cell shows the service name for service requests and the
  # user email for regular members. `service` is a preloaded `%Service{}` on
  # durable logs, or a `%{name: ...}` map on pending (in-flight) rows.
  defp member_display(%{subject_type: "service", service: %{name: name}}), do: name
  defp member_display(%{subject_type: "service"}), do: "—"
  defp member_display(log), do: member_email(log)

  # The "Perfil de límites" cell resolves from the member's group (user requests) or the
  # service's group (service requests — including in-flight rows that carry
  # group_name from the virtual member).
  defp member_group(%{group_member: %{group: %{name: name}}}), do: name
  defp member_group(%{subject_type: "service", service: %{group: %{name: name}}}), do: name
  defp member_group(%{group_member: %{group_name: name}}) when is_binary(name), do: name
  defp member_group(_), do: "—"

  defp provider_name(%{provider: %{name: name}}), do: name
  defp provider_name(_), do: "—"

  # "API Key": label de la key viva (join por `api_key_id`), si no el prefijo
  # histórico (`api_key_prefix`), que es lo único que tienen las filas viejas.
  # Las opciones del selector ya traen {display, id} de las keys con logs, así
  # que el label sale de ahí sin una query por fila.
  defp api_key_display(%{api_key_id: id} = log, options) when is_binary(id) do
    case api_key_option_display(options, id) do
      label when is_binary(label) and label != "" -> label
      _ -> api_key_display_from_prefix(log)
    end
  end

  defp api_key_display(log, _options), do: api_key_display_from_prefix(log)

  # Las filas viejas no tienen `api_key_id`: se cae al prefijo histórico.
  defp api_key_display_from_prefix(%{api_key_prefix: prefix})
       when is_binary(prefix) and prefix != "",
       do: prefix

  defp api_key_display_from_prefix(%{api_key_prefix: prefix}) when prefix != nil,
    do: to_string(prefix)

  defp api_key_display_from_prefix(_), do: "—"

  defp api_key_option_display(options, id),
    do: Map.new(options, &{elem(&1, 1), elem(&1, 0)})[id] || ""

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

  # "Agent": the stored row keeps the raw HTTP identity (`client_agent`: X-Title
  # → User-Agent → X-Agent-Type) and `agent_type` (X-Agent-Type). The cell
  # normalizes it at read time to the identified agent ("opencode v2") and
  # leaves the raw value in the tooltip, so historical rows read as agents
  # without a backfill. In-flight rows are plain maps and may lack
  # `agent_type`, hence Map.get/2 everywhere.
  defp agent_display(log) do
    client_agent = Map.get(log, :client_agent)
    agent_type = Map.get(log, :agent_type)

    if blank_identity?(client_agent) and blank_identity?(agent_type) do
      "—"
    else
      Tokengate.Agents.label(client_agent, agent_type)
    end
  end

  # Brand logo (or hero fallback) for the cell; nil when the identity is blank.
  defp agent_mark(log) do
    client_agent = Map.get(log, :client_agent)
    agent_type = Map.get(log, :agent_type)

    if blank_identity?(client_agent) and blank_identity?(agent_type) do
      nil
    else
      identity = Tokengate.Agents.identify(client_agent, agent_type)
      %{logo: identity.logo, icon: identity.icon}
    end
  end

  defp blank_identity?(nil), do: true
  defp blank_identity?(""), do: true
  defp blank_identity?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_identity?(_), do: true

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
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="space-y-6">
        <.header>
          Monitoring
          <:subtitle>{gettext("Real-time API request log")}</:subtitle>
        </.header>

        <%!-- KPI strip: summary cards, 4 in a row --%>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <%!-- Top 3 modelos último minuto --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm" id="top-models">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  {gettext("Top 3 models · last minute")}
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
                  {gettext("Top 3 users · last minute")}
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
                  {gettext("Performance")}
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
                  <p class="text-xs text-base-content/40">{gettext("Avg latency")}</p>
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
                  {gettext("Errors")}
                </p>
                <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-base-content/40" />
              </div>
              <div class="mt-1 space-y-1">
                <div class="flex items-center justify-between">
                  <p class="text-xs text-base-content/40">{gettext("Errors")}</p>
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
                  <p class="text-xs text-base-content/40">{gettext("Rate")}</p>
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
          class="grid grid-cols-9 gap-3"
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
            label="Streaming"
          />
          <.input
            field={@form[:model_search]}
            type="select"
            prompt={gettext("All")}
            options={@model_options}
            label={gettext("Model")}
          />
          <.input
            field={@form[:group_id]}
            type="select"
            prompt={gettext("All")}
            options={@group_options}
            label={gettext("Limit profile")}
          />
          <.input
            field={@form[:subject_type]}
            type="select"
            prompt={gettext("All")}
            options={[{gettext("User"), "user"}, {gettext("Service"), "service"}]}
            label={gettext("Type")}
          />
          <.input
            field={@form[:api_key_id]}
            type="select"
            prompt={gettext("All keys")}
            options={@api_key_options}
            label="API Key"
          />
          <.input
            field={@form[:error_reason]}
            type="select"
            prompt={gettext("All")}
            options={[
              {"rate_limited", "rate_limited"},
              {"timeout", "timeout"},
              {"server_error", "server_error"},
              {"auth_error", "auth_error"},
              {"bad_request", "bad_request"},
              {"client_error", "client_error"}
            ]}
            label="Error"
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

        <div class="flex flex-wrap justify-end gap-2">
          <.link
            href="/stats/export?type=logs&period=30d"
            class="btn btn-sm btn-ghost"
            id="csv-logs-30d"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV Logs 30d
          </.link>
          <.link
            href="/stats/export?type=logs&period=yesterday"
            class="btn btn-sm btn-ghost"
            id="csv-logs-yesterday"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("CSV Logs (yesterday)")}
          </.link>
          <.link
            href="/stats/export?type=errors"
            class="btn btn-sm btn-ghost"
            id="csv-errors"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("CSV Errors")}
          </.link>
        </div>

        <%!-- Logs feed. El stream está acotado a @max_stream_rows (ver
             prepend_log/2): las filas in-flight llegan por el mismo stream con
             `__pending__: true` y se distinguen por su badge + el ping. --%>
        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="logs"
            rows={@streams.logs}
            row_item={fn {_id, log} -> log end}
            row_class={
              fn {_id, log} ->
                ["align-top", Map.get(log, :__pending__) && "bg-warning/20 hover:bg-warning/30"]
              end
            }
            empty?={@stream_rows == 0}
          >
            <:col :let={log} label={gettext("Date")}>
              <div class="whitespace-nowrap text-sm">
                <%= if Map.get(log, :__pending__) do %>
                  <span class="flex items-center gap-1.5 font-medium">
                    <span class="relative flex h-2 w-2">
                      <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-warning opacity-60"></span>
                      <span class="relative inline-flex rounded-full h-2 w-2 bg-warning"></span>
                    </span>
                    {format_datetime(log.inserted_at, @timezone)}
                  </span>
                <% else %>
                  {format_datetime(log.inserted_at, @timezone)}
                <% end %>
              </div>
            </:col>
            <:col :let={log} label={gettext("Model")}>
              <span class="text-sm">
                {if Map.get(log, :__pending__),
                  do: log.model_requested,
                  else: model_display(log.model_requested, log.model_responded)}
              </span>
            </:col>
            <:col :let={log} label={gettext("Type")}>
              <span :if={log.subject_type == "service"} class="badge badge-sm badge-info">
                {gettext("Service")}
              </span>
              <span :if={log.subject_type != "service"} class="badge badge-sm badge-ghost">
                {gettext("User")}
              </span>
            </:col>
            <:col :let={log} label={gettext("User")}>
              <span class="text-sm">{member_display(log)}</span>
            </:col>
            <:col :let={log} label={gettext("Limit profile")}>
              <span class="text-sm">{member_group(log)}</span>
            </:col>
            <:col :let={log} label={gettext("Agent")}>
              <span
                class="flex items-center gap-1.5 text-sm"
                title={Map.get(log, :client_agent) || Map.get(log, :agent_type)}
              >
                <%= if mark = agent_mark(log) do %>
                  <img
                    :if={mark.logo}
                    src={mark.logo}
                    alt=""
                    class="w-4 h-4 object-contain shrink-0"
                  />
                  <.icon :if={!mark.logo} name={mark.icon} class="w-4 h-4 opacity-70 shrink-0" />
                <% end %>
                {agent_display(log)}
              </span>
            </:col>
            <:col :let={log} label={gettext("API key")}>
              <span class="text-sm">{api_key_display(log, @api_key_options)}</span>
            </:col>
            <:col :let={log} label={gettext("Provider")}>
              <span class="text-sm">{provider_name(log)}</span>
            </:col>
            <:col
              :let={log}
              label={gettext("Prov. key")}
              tooltip={gettext("Provider API key or model")}
            >
              <span
                class="text-sm"
                title={
                  if Map.get(log, :credential_name) not in [nil, ""],
                    do: Map.get(log, :credential_name)
                }
              >
                {prov_key_display(log)}
              </span>
            </:col>
            <:col :let={log} label={gettext("Prov. status")} tooltip={gettext("Provider HTTP status")}>
              <span :if={log.provider_status_code} class="badge badge-sm badge-ghost">
                {log.provider_status_code}
              </span>
              <span :if={!log.provider_status_code} class="text-sm text-base-content/40">—</span>
            </:col>
            <:col :let={log} label={gettext("Error")} tooltip={gettext("Provider error reason")}>
              <div class="min-w-[180px]">
                <%= if Map.get(log, :__pending__) do %>
                  <span class="text-sm text-base-content/40">—</span>
                <% else %>
                  <div :if={log.error_reason} class="flex flex-col gap-0.5 items-start">
                    <button
                      type="button"
                      class="badge badge-sm badge-error cursor-pointer hover:badge-error/80 transition-colors"
                      phx-click="show_error"
                      phx-value-log-id={log.id}
                      phx-value-inserted-at={DateTime.to_iso8601(log.inserted_at)}
                      title={gettext("View full error detail")}
                      aria-label={gettext("View full error detail")}
                    >
                      {log.error_reason}
                    </button>
                    <button
                      :if={log.error_message}
                      type="button"
                      class="text-left text-xs text-base-content/60 max-w-[220px] truncate cursor-pointer hover:text-base-content transition-colors"
                      phx-click="show_error"
                      phx-value-log-id={log.id}
                      phx-value-inserted-at={DateTime.to_iso8601(log.inserted_at)}
                      title={log.error_message}
                    >
                      {log.error_message}
                    </button>
                  </div>
                  <span :if={!log.error_reason} class="text-sm text-base-content/40">—</span>
                <% end %>
              </div>
            </:col>
            <:col
              :let={log}
              label={gettext("Status")}
              tooltip={gettext("HTTP status sent to the client")}
            >
              <%= if Map.get(log, :__pending__) do %>
                <span class="badge badge-sm badge-warning">{gettext("In flight")}</span>
              <% else %>
                <span class={["badge", "badge-sm", status_badge_class(log.status_code)]}>
                  {log.status_code}
                </span>
                <span
                  :if={log.status_code == 200 && log.error_reason}
                  class="badge badge-sm badge-warning ml-1"
                  title={
                    gettext(
                      "The provider failed and the request was recovered by falling back to another provider"
                    )
                  }
                >
                  fallback
                </span>
              <% end %>
            </:col>
            <:col :let={log} label="Think">
              <.think_badge value={log.think} />
            </:col>
            <:col :let={log} label="Effort">
              <span class="text-sm inline-flex items-center gap-1.5">
                {log.effort || "—"}
                <%!-- Operator effort policy rewrite: the client's
                     intent and what travelled to the wire differ. --%>
                <span
                  :if={
                    Map.get(log, :effort_applied) &&
                      Map.get(log, :effort_applied) != log.effort
                  }
                  class="badge badge-sm badge-accent"
                  title={
                    gettext(
                      "Reasoning effort the gateway sent upstream after the operator's effort policy"
                    )
                  }
                >
                  {log.effort || "∅"} → {Map.get(log, :effort_applied)}
                </span>
              </span>
            </:col>
            <:col :let={log} label={gettext("Streaming")}>
              <span class="text-sm">{if log.streaming, do: gettext("Yes"), else: gettext("No")}</span>
            </:col>
            <:col :let={log} label={gettext("Input")} align="right">
              <span class="text-sm tabular-nums">
                {if Map.get(log, :__pending__), do: "—", else: format_number(log.prompt_tokens)}
              </span>
            </:col>
            <:col :let={log} label={gettext("Output")} align="right">
              <span class="text-sm tabular-nums">
                {if Map.get(log, :__pending__), do: "—", else: format_number(log.completion_tokens)}
              </span>
            </:col>
            <:col :let={log} label={gettext("Cache R")} align="right" tooltip={gettext("Cache read")}>
              <span class="text-sm tabular-nums">{format_cache_tokens(log.cache_read_tokens)}</span>
            </:col>
            <:col :let={log} label="TPS" align="right">
              <span class="text-sm tabular-nums text-base-content/70">
                {tps(log.completion_tokens, log.latency_ms)}
              </span>
            </:col>
            <:col
              :let={log}
              label="TTFT"
              tooltip={gettext("Time to first token — streaming only")}
            >
              <span class="text-sm text-base-content/70">{format_ttft(log.ttft_ms)}</span>
            </:col>
            <:col :let={log} label={gettext("Latency")}>
              <span class="text-sm">
                {if Map.get(log, :__pending__), do: "—", else: "#{log.latency_ms}ms"}
              </span>
            </:col>
            <:col :let={log} label={gettext("Cost")} align="right">
              <span class="text-sm tabular-nums">
                {if Map.get(log, :__pending__), do: "—", else: format_cost(log.provider_cost_usd)}
              </span>
            </:col>
            <:empty>
              <div id="logs-empty-state">
                <.icon name="hero-funnel" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                <p>{gettext("No logs match the filters.")}</p>
              </div>
            </:empty>
          </.table>
        </div>

        <%!-- Load more --%>
        <div class="flex justify-center">
          <button
            :if={@has_more}
            phx-click="load_more"
            class="btn btn-primary btn-sm"
            id="load-more-btn"
          >
            <.icon name="hero-chevron-down" class="w-4 h-4" /> {gettext("Load more")}
          </button>
        </div>
      </div>

      <%!-- Error detail modal: el mensaje del upstream llega truncado a 255
           bytes por la columna; aquí se ve entero con su contexto. --%>
      <div
        :if={@error_detail}
        id="error-detail-modal"
        class="modal modal-open"
        phx-click-away="close_error"
      >
        <div class="modal-box max-w-2xl">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <h3 class="text-lg font-bold flex items-center gap-2 flex-wrap">
                <span class="badge badge-error">{@error_detail.error_reason}</span>
                <span class="text-base-content/70 font-mono text-sm">
                  {gettext("client")} {@error_detail.status_code}
                </span>
                <span
                  :if={@error_detail.provider_status_code}
                  class="text-base-content/50 font-mono text-sm"
                >
                  · {gettext("provider")} {@error_detail.provider_status_code}
                </span>
              </h3>
              <p class="text-sm text-base-content/50 mt-1 truncate">
                {format_datetime(@error_detail.inserted_at, @timezone)} · {model_display(
                  @error_detail.model_requested,
                  @error_detail.model_responded
                )} · {provider_name(@error_detail)}
              </p>
            </div>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-circle"
              phx-click="close_error"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div class="mt-4">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1.5">
              {gettext("Upstream message")}
            </p>
            <pre
              id="error-detail-message"
              phx-no-curly-interpolation
              class="text-sm bg-base-200/60 rounded-lg p-3 whitespace-pre-wrap break-words font-mono"
            >{@error_detail.error_message || gettext("No error message recorded")}</pre>
          </div>

          <div class="mt-4 grid grid-cols-2 gap-x-6 gap-y-1.5 text-sm">
            <div class="flex justify-between gap-2 border-b border-base-200/60 py-0.5">
              <span class="text-base-content/50">{gettext("User")}</span>
              <span class="font-medium truncate">{member_display(@error_detail)}</span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200/60 py-0.5">
              <span class="text-base-content/50">{gettext("Group")}</span>
              <span class="font-medium truncate">{member_group(@error_detail)}</span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200/60 py-0.5">
              <span class="text-base-content/50">{gettext("API Key")}</span>
              <span class="font-medium truncate font-mono">
                {api_key_display(@error_detail, @api_key_options)}
              </span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200/60 py-0.5">
              <span class="text-base-content/50">{gettext("Provider key")}</span>
              <span
                class="font-medium truncate font-mono"
                title={@error_detail.credential_name}
              >
                {prov_key_display(@error_detail)}
              </span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200/60 py-0.5">
              <span class="text-base-content/50">{gettext("Streaming")}</span>
              <span class="font-medium">
                {if(@error_detail.streaming, do: gettext("Yes"), else: gettext("No"))}
              </span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200/60 py-0.5">
              <span class="text-base-content/50">{gettext("Latency")}</span>
              <span class="font-medium">{@error_detail.latency_ms}ms</span>
            </div>
          </div>
        </div>

        <div phx-click="close_error" class="modal-backdrop cursor-pointer">
          <button class="cursor-pointer">{gettext("Close")}</button>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
