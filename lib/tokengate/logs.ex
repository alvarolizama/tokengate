defmodule Tokengate.Logs do
  @moduledoc """
  The Logs context: append-only request log entries.

  In normal operation this context only **inserts** and **queries** request
  logs — never updates or deletes. The deliberate exceptions are the admin
  utilities `truncate_request_logs/0` (destructive maintenance TRUNCATE) and
  `Tokengate.Logs.CostBackfill` (recomputes `provider_cost_usd` from manual
  pricing). The `request_logs` table is a native Postgres RANGE-partitioned
  table on `inserted_at` (daily granularity).

  ## Privacy

  This table **never** stores prompt or completion content — only metadata
  (token counts, costs, latency, status). No PII or request/response bodies
  are persisted here.
  """

  import Ecto.Query, warn: false
  alias Tokengate.Repo
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Accounts.GroupMember

  @default_limit 50
  @max_limit 500
  # CSV exports need far more rows than the paginated UI; a dedicated cap
  # keeps `list_logs/1` bounded at 500 while exports can stream up to 50k.
  @export_limit 50_000

  # Etiqueta de los logs sin proveedor en el desglose por hora del día
  # (fallo antes del routing, o provider ya borrado). Es un valor de DATOS:
  # `Metrics.Rollup` tiene que devolver el MISMO string para que la tarjeta
  # compartida no cambie de nombre entre pestañas. La traducción se hace al
  # pintar (`TokengateWeb.StatsHelpers.provider_label/1`).
  @no_provider "no provider"

  # ---------------------------------------------------------------------------
  # Insert
  # ---------------------------------------------------------------------------

  @doc """
  Inserts a request log entry. Generates `id` and `inserted_at` (defaults to
  `DateTime.utc_now() |> DateTime.truncate(:second)`) if not provided in attrs.

  Returns `{:ok, request_log}` or `{:error, changeset}`.
  """
  def log_request(attrs) do
    inserted_at =
      Map.get(attrs, :inserted_at) ||
        Map.get(attrs, "inserted_at") ||
        DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> ensure_atom_key(:inserted_at, inserted_at)

    %RequestLog{}
    |> RequestLog.changeset(attrs)
    |> Repo.insert()
  end

  defp ensure_atom_key(map, key, value) when is_map(map) do
    # Accept both atom and string-keyed maps; normalize to atom key.
    map
    |> Map.delete(to_string(key))
    |> Map.put(key, value)
  end

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  @doc """
  Lists request logs with optional filters.

  ## Filters (all optional)
    * `:group_member_id` — exact match
    * `:group_member_ids` — list of allowed group_member ids (OR)
    * `:group_id` — exact match, joined through `group_members`
    * `:provider_id` — exact match
    * `:model_id` — exact match
    * `:agent_type` — exact match
    * `:status_code` — exact match
    * `:streaming` — boolean
    * `:from` — `inserted_at >= from` (DateTime)
    * `:to` — `inserted_at <= to` (DateTime)
    * `:limit` — default 50, max 500
  """
  def list_logs(filters \\ %{}) do
    limit = clamp_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    RequestLog
    |> apply_log_filters(filters)
    |> order_by([rl], desc: rl.inserted_at)
    |> limit(^limit)
    |> preload(group_member: [:user, :group])
    |> preload(service: [:api_key])
    |> preload(:provider)
    |> Repo.all()
  end

  @doc """
  Lists request logs for CSV export with a much higher row cap than the
  paginated UI (`list_logs/1` is capped at #{@max_limit}).

  Same filters as `list_logs/1`. The cap is `#{@export_limit}` rows — an
  explicit `:limit` filter is honored up to that bound.

  NOTE: the preload of user/group makes this expensive at scale; it is only
  meant for one-off export requests, never the paginated UI path.
  """
  def list_logs_for_export(filters \\ %{}) do
    limit =
      case Map.get(filters, :limit) || Map.get(filters, "limit") do
        nil -> @export_limit
        n when is_integer(n) and n > 0 -> min(n, @export_limit)
        _ -> @export_limit
      end

    RequestLog
    |> apply_log_filters(filters)
    |> order_by([rl], desc: rl.inserted_at)
    |> limit(^limit)
    |> preload(group_member: [:user, :group])
    |> preload(service: [:api_key])
    |> preload(:provider)
    |> Repo.all()
  end

  @doc """
  Lists request logs with `inserted_at` strictly after `since` (DateTime),
  ordered newest-first. Used by the MonitoringLive real-time subscription to
  fetch new logs appended after page load.

  Same filter support as `list_logs/1` (scope, status, agent, etc.), but
  the `before` cursor is ignored. A defensive `limit` caps how many new
  logs are returned in a single real-time refresh (default 500 — or 100
  when no `since` cursor is supplied).
  """
  def list_logs_after(since, filters \\ %{})

  def list_logs_after(nil, filters) do
    list_logs(Map.put(filters, :limit, Map.get(filters, :limit, 100)))
  end

  def list_logs_after(%DateTime{} = since, filters) do
    filters =
      filters
      |> Map.delete(:before)
      |> Map.delete("before")
      |> Map.put(:after, since)

    limit = clamp_limit(Map.get(filters, :limit) || Map.get(filters, "limit") || 500)

    RequestLog
    |> apply_log_filters(filters)
    |> order_by([rl], desc: rl.inserted_at)
    |> limit(^limit)
    |> preload(group_member: [:user, :group])
    |> preload(service: [:api_key])
    |> preload(:provider)
    |> Repo.all()
  end

  @doc """
  Lists request logs for a specific group, joining through `group_members`.

  Filters are the same as `list_logs/1`.
  """
  def list_logs_for_group(group_id, filters \\ %{}) do
    limit = clamp_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    RequestLog
    |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
    |> where([rl, tm], tm.group_id == ^group_id)
    |> apply_log_filters(filters)
    |> order_by([rl], desc: rl.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp apply_log_filters(query, filters) do
    query
    |> maybe_where(:group_member_id, filters)
    |> maybe_where(:service_id, filters)
    |> maybe_where_subject_id(filters)
    |> maybe_where(:subject_type, filters)
    |> maybe_where(:api_key_id, filters)
    |> maybe_where_member_ids(filters)
    |> maybe_where_user_ids(filters)
    |> maybe_where_group_id(filters)
    |> maybe_where(:provider_id, filters)
    |> maybe_where(:credential_id, filters)
    |> maybe_where(:model_id, filters)
    |> maybe_where(:agent_type, filters)
    |> maybe_where(:status_code, filters)
    |> maybe_status_class(filters)
    |> maybe_model_search(filters)
    |> maybe_error_reason(filters)
    |> maybe_where(:streaming, filters)
    |> maybe_from(filters)
    |> maybe_to(filters)
    |> maybe_before(filters)
    |> maybe_after(filters)
  end

  # Filter by group_id through the group_members join. When group_id is present we
  # INNER JOIN group_members so the WHERE references both bindings.
  defp maybe_where_group_id(query, filters) do
    value = Map.get(filters, :group_id) || Map.get(filters, "group_id")

    case value do
      nil ->
        query

      group_id ->
        tm =
          GroupMember
          |> where([tm], tm.group_id == ^group_id)
          |> select([tm], tm.id)

        where(query, [rl], rl.group_member_id in subquery(tm))
    end
  end

  defp maybe_where(query, field, filters) do
    value = Map.get(filters, field)
    value = if is_nil(value), do: Map.get(filters, to_string(field)), else: value

    if is_nil(value), do: query, else: where(query, [rl], field(rl, ^field) == ^value)
  end

  defp maybe_where_member_ids(query, filters) do
    value = Map.get(filters, :group_member_ids) || Map.get(filters, "group_member_ids")

    case value do
      nil -> query
      ids when is_list(ids) -> where(query, [rl], rl.group_member_id in ^ids)
    end
  end

  # Scoping por usuario (identidad durable): el camino del dashboard y de
  # cualquier lectura que deba cuadrar con el motor de créditos.
  defp maybe_where_user_ids(query, filters) do
    value = Map.get(filters, :user_ids) || Map.get(filters, "user_ids")

    case value do
      nil -> query
      ids when is_list(ids) -> where(query, [rl], rl.user_id in ^ids)
    end
  end

  # Matches a log whose subject is *either* a group member or a service with
  # the given id. Used by `Budgets.Manager` (which keys both member and service
  # spend by a single binary subject id) to lazily load spend from the durable
  # log table without knowing which kind of subject it is.
  defp maybe_where_subject_id(query, filters) do
    case Map.get(filters, :subject_id) || Map.get(filters, "subject_id") do
      nil -> query
      id -> where(query, [rl], rl.group_member_id == ^id or rl.service_id == ^id)
    end
  end

  defp maybe_status_class(query, filters) do
    case Map.get(filters, :status_class) || Map.get(filters, "status_class") do
      nil -> query
      "" -> query
      "2xx" -> where(query, [rl], rl.status_code >= 200 and rl.status_code < 300)
      "4xx" -> where(query, [rl], rl.status_code >= 400 and rl.status_code < 500)
      "5xx" -> where(query, [rl], rl.status_code >= 500 and rl.status_code < 600)
      "errors" -> where(query, [rl], rl.status_code >= 400)
      _ -> query
    end
  end

  defp maybe_model_search(query, filters) do
    case Map.get(filters, :model_search) || Map.get(filters, "model_search") do
      nil ->
        query

      "" ->
        query

      search ->
        pattern = "%#{search}%"

        where(
          query,
          [rl],
          ilike(rl.model_requested, ^pattern) or ilike(rl.model_responded, ^pattern)
        )
    end
  end

  defp maybe_error_reason(query, filters) do
    case Map.get(filters, :error_reason) || Map.get(filters, "error_reason") do
      nil -> query
      "" -> query
      reason -> where(query, [rl], rl.error_reason == ^reason)
    end
  end

  defp maybe_from(query, filters) do
    case Map.get(filters, :from) || Map.get(filters, "from") do
      nil -> query
      from -> where(query, [rl], rl.inserted_at >= ^from)
    end
  end

  defp maybe_to(query, filters) do
    case Map.get(filters, :to) || Map.get(filters, "to") do
      nil -> query
      to -> where(query, [rl], rl.inserted_at <= ^to)
    end
  end

  defp maybe_before(query, filters) do
    case Map.get(filters, :before) || Map.get(filters, "before") do
      nil -> query
      before -> where(query, [rl], rl.inserted_at < ^before)
    end
  end

  defp maybe_after(query, filters) do
    case Map.get(filters, :after) || Map.get(filters, "after") do
      nil -> query
      after_dt -> where(query, [rl], rl.inserted_at > ^after_dt)
    end
  end

  @doc """
  Top models by request count in the last N minutes (default 1, limit 3).
  Accepts the same filter map as `list_logs/1` (group_member_ids, agent_type,
  model_search, etc.) so the cards respect the active filters.
  Returns [%{model: String.t(), count: integer}].
  """
  def top_models_last_minutes(minutes \\ 1, limit \\ 3, filters \\ %{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    RequestLog
    |> where([rl], rl.inserted_at >= ^cutoff)
    |> where([rl], not is_nil(rl.model_requested))
    |> apply_log_filters(filters)
    |> group_by([rl], rl.model_requested)
    |> order_by([rl], desc: count(rl.id))
    |> limit(^limit)
    |> select([rl], %{model: rl.model_requested, count: count(rl.id)})
    |> Repo.all()
  end

  @doc """
  Top users by request count in the last N minutes (default 1, limit 3).
  Accepts the same filter map as `list_logs/1` so the cards respect the
  active filters. Returns [%{user: String.t(), count: integer}].
  """
  def top_users_last_minutes(minutes \\ 1, limit \\ 3, filters \\ %{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    RequestLog
    |> where([rl], rl.inserted_at >= ^cutoff)
    |> apply_log_filters(filters)
    |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
    |> join(:inner, [rl, tm], u in assoc(tm, :user))
    |> group_by([rl, tm, u], u.email)
    |> order_by([rl], desc: count(rl.id))
    |> limit(^limit)
    |> select([rl, tm, u], %{user: u.email, count: count(rl.id)})
    |> Repo.all()
  end

  defp clamp_limit(nil), do: @default_limit

  defp clamp_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @max_limit)
  end

  defp clamp_limit(_), do: @default_limit

  # ---------------------------------------------------------------------------
  # Aggregates
  # ---------------------------------------------------------------------------

  @doc """
  Computes a cost summary over request logs for a specific group, joining
  through `group_members`.

  Returns the same shape as `cost_summary/1`:
    * `:total_cost_usd`
    * `:total_prompt_tokens`
    * `:total_completion_tokens`
    * `:total_cache_read_tokens`
    * `:total_cache_creation_tokens`
    * `:request_count`

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  def cost_summary_for_group(group_id, opts \\ %{}) do
    from = Map.get(opts, :from)
    to = Map.get(opts, :to)

    query =
      RequestLog
      |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
      |> where([rl, tm], tm.group_id == ^group_id)
      |> maybe_group_from(from)
      |> maybe_group_to(to)
      |> select([rl], %{
        total_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)"),
        total_prompt_tokens: coalesce(sum(rl.prompt_tokens), 0),
        total_completion_tokens: coalesce(sum(rl.completion_tokens), 0),
        total_cache_read_tokens: coalesce(sum(rl.cache_read_tokens), 0),
        total_cache_creation_tokens: coalesce(sum(rl.cache_creation_tokens), 0),
        request_count: count(rl.id)
      })

    result = Repo.one(query)

    %{
      total_cost_usd: Decimal.new(to_string(result.total_cost_usd)),
      total_prompt_tokens: result.total_prompt_tokens,
      total_completion_tokens: result.total_completion_tokens,
      total_cache_read_tokens: result.total_cache_read_tokens,
      total_cache_creation_tokens: result.total_cache_creation_tokens,
      request_count: result.request_count
    }
  end

  defp maybe_group_from(query, nil), do: query
  defp maybe_group_from(query, from), do: where(query, [rl], rl.inserted_at >= ^from)

  defp maybe_group_to(query, nil), do: query
  defp maybe_group_to(query, to), do: where(query, [rl], rl.inserted_at <= ^to)

  @doc """
  Computes a cost summary over request logs for a specific set of group
  members (by their ids).

  Returns the same shape as `cost_summary/1`. Used by the dashboard for
  the "user" scope (a user's own consumption across all their memberships).

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  def cost_summary_for_members(group_member_ids, opts \\ %{})

  def cost_summary_for_members([], _opts) do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      request_count: 0
    }
  end

  def cost_summary_for_members(group_member_ids, opts) when is_list(group_member_ids) do
    from = Map.get(opts, :from)
    to = Map.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.group_member_id in ^group_member_ids)
      |> maybe_members_from(from)
      |> maybe_members_to(to)
      |> select([rl], %{
        total_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)"),
        total_prompt_tokens: coalesce(sum(rl.prompt_tokens), 0),
        total_completion_tokens: coalesce(sum(rl.completion_tokens), 0),
        total_cache_read_tokens: coalesce(sum(rl.cache_read_tokens), 0),
        total_cache_creation_tokens: coalesce(sum(rl.cache_creation_tokens), 0),
        request_count: count(rl.id)
      })

    result = Repo.one(query)

    %{
      total_cost_usd: Decimal.new(to_string(result.total_cost_usd)),
      total_prompt_tokens: result.total_prompt_tokens,
      total_completion_tokens: result.total_completion_tokens,
      total_cache_read_tokens: result.total_cache_read_tokens,
      total_cache_creation_tokens: result.total_cache_creation_tokens,
      request_count: result.request_count,
      avg_latency_ms: nil,
      avg_tps: 0.0,
      avg_ttft_ms: nil
    }
  end

  defp maybe_members_from(query, nil), do: query
  defp maybe_members_from(query, from), do: where(query, [rl], rl.inserted_at >= ^from)

  defp maybe_members_to(query, nil), do: query
  defp maybe_members_to(query, to), do: where(query, [rl], rl.inserted_at <= ^to)

  @doc """
  Computes a cost summary over request logs matching the given filters.

  Returns a map with:
    * `:total_cost_usd`
    * `:total_prompt_tokens`
    * `:total_completion_tokens`
    * `:total_cache_read_tokens`
    * `:total_cache_creation_tokens`
    * `:request_count`
    * `:avg_latency_ms` — mean latency over matched rows (`nil` when none)
    * `:avg_tps` — approximate tokens-per-second: `SUM(completion_tokens) /
      (SUM(latency_ms) / 1000)`. Assumes output is the dominant phase; nil
      when no latency samples are present.
    * `:avg_ttft_ms` — mean time-to-first-token over streaming rows (`nil`
      when no streaming samples are present; AVG skips NULLs).

  All sums are Decimal-safe (use `COALESCE` + `SUM` in SQL). Token sums
  default to 0 when no rows match.
  """
  def cost_summary(filters \\ %{}) do
    result =
      RequestLog
      |> apply_log_filters(filters)
      |> select([rl], %{
        total_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)"),
        total_prompt_tokens: coalesce(sum(rl.prompt_tokens), 0),
        total_completion_tokens: coalesce(sum(rl.completion_tokens), 0),
        total_cache_read_tokens: coalesce(sum(rl.cache_read_tokens), 0),
        total_cache_creation_tokens: coalesce(sum(rl.cache_creation_tokens), 0),
        request_count: count(rl.id),
        total_latency_ms: fragment("COALESCE(SUM(latency_ms), 0)"),
        avg_latency_ms: fragment("AVG(latency_ms)"),
        avg_ttft_ms: fragment("AVG(ttft_ms)")
      })
      |> Repo.one()

    %{
      total_cost_usd: Decimal.new(to_string(result.total_cost_usd)),
      total_prompt_tokens: result.total_prompt_tokens,
      total_completion_tokens: result.total_completion_tokens,
      total_cache_read_tokens: result.total_cache_read_tokens,
      total_cache_creation_tokens: result.total_cache_creation_tokens,
      request_count: result.request_count,
      # Lo devuelve el SELECT pero hace falta en el mapa: el lado crudo del
      # híbrido (`StatsQueries.merge_summaries/2`) suma latency para el
      # avg_tps combinado — sin él, el KPI TPS pierde la latencia fresca.
      total_latency_ms: result.total_latency_ms,
      avg_latency_ms: avg_to_float(result.avg_latency_ms),
      avg_ttft_ms: avg_to_float(result.avg_ttft_ms),
      avg_tps: compute_avg_tps(result.total_completion_tokens, result.total_latency_ms)
    }
  end

  @doc """
  Rolling-window realtime summary for the live logs KPI strip.

  Same filters as `cost_summary/1` (via `apply_log_filters/2`) plus a hard
  `inserted_at >= now - window_seconds` cutoff, so the numbers always
  describe *what is happening right now* instead of lifetime totals.

  Returns a map with:

    * `:request_count` — requests seen inside the window
    * `:req_per_min` — `request_count / (window_seconds / 60)`, 1 decimal
    * `:avg_latency_ms` — mean `latency_ms` over matched rows (`nil` when none)
    * `:error_count` — rows with `status_code >= 400`
    * `:error_rate` — percentage of errors over matched rows (0.0 when none)

  `window_seconds` defaults to 300 (5 minutes).
  """
  def realtime_summary(filters \\ %{}, window_seconds \\ 300) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-window_seconds, :second)
      |> DateTime.truncate(:second)

    result =
      RequestLog
      |> apply_log_filters(filters)
      |> where([rl], rl.inserted_at >= ^cutoff)
      |> select([rl], %{
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE status_code >= 400)"),
        avg_latency_ms: fragment("AVG(latency_ms)")
      })
      |> Repo.one()

    request_count = result.request_count
    error_count = result.error_count

    %{
      request_count: request_count,
      req_per_min: Float.round(request_count / (window_seconds / 60), 1),
      avg_latency_ms: avg_to_float(result.avg_latency_ms),
      error_count: error_count,
      error_rate: error_rate(request_count, error_count)
    }
  end

  # ---------------------------------------------------------------------------
  # Realtime dashboard (/stats "En vivo")
  # ---------------------------------------------------------------------------

  @doc """
  Per-minute request/token/cost series for the last `minutes` minutes
  (default 60), bucketed by `date_trunc('minute', inserted_at)` in UTC,
  zero-filled so the chart always renders a full window.

  Every bucket carries the full metric set:

    * `:request_count` — requests seen in that minute
    * `:prompt_tokens` / `:completion_tokens` — tokens consumed
    * `:cost_usd` — provider-reported cost (`Decimal`)

  Cheap by design: one grouped range scan over `inserted_at`, no joins.
  """
  @spec requests_per_minute(non_neg_integer()) :: [map()]
  def requests_per_minute(minutes \\ 60) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    rows =
      RequestLog
      |> where([rl], rl.inserted_at >= ^cutoff)
      |> group_by([rl], fragment("date_trunc('minute', ?)", rl.inserted_at))
      |> select([rl], %{
        bucket: fragment("date_trunc('minute', ?)", rl.inserted_at),
        request_count: count(rl.id),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
      })
      |> Repo.all()
      |> Map.new(fn row ->
        {minute_key(row.bucket),
         %{
           request_count: row.request_count,
           prompt_tokens: row.prompt_tokens,
           completion_tokens: row.completion_tokens,
           cost_usd: Decimal.new(to_string(row.cost_usd))
         }}
      end)

    empty = %{
      request_count: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: Decimal.new(0)
    }

    now = DateTime.utc_now()

    for i <- (minutes - 1)..0//-1 do
      # NaiveDateTime (UTC) to match what date_trunc returns on the
      # timestamp-without-timezone column — otherwise the Map.get keys
      # never line up.
      bucket =
        now
        |> DateTime.add(-i * 60, :second)
        |> DateTime.to_naive()
        |> truncate_to_minute()

      bucket
      |> then(&Map.get(rows, minute_key(&1), empty))
      |> Map.put(:bucket, bucket)
    end
  end

  # Canonical map key for a minute bucket. Postgres returns `date_trunc` with
  # microsecond precision `{0, 6}` while the zero-fill builds `{0, 0}`, and
  # `NaiveDateTime` keys compare structurally — so both sides must be folded
  # onto the same representation or every lookup misses.
  defp minute_key(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  # date_trunc('minute') equivalent: drops seconds AND microseconds.
  defp truncate_to_minute(%NaiveDateTime{} = dt) do
    %{dt | second: 0, microsecond: {0, 0}}
  end

  @doc """
  Calendar-day summary for the "En vivo" tab (KPIs de hoy): request count,
  cost, tokens and latency (avg + nearest-rank p95) since local midnight.

  `timezone` determines "hoy" (00:00 local → UTC cutoff). Single index
  range scan over `inserted_at` with a one-pass aggregate.
  """
  @spec today_summary(String.t()) :: map()
  def today_summary(timezone \\ "Etc/UTC") do
    from = Tokengate.Periods.start_of_day_utc(timezone)

    result =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from)
      |> select([rl], %{
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_creation_tokens),
        avg_latency_ms: fragment("AVG(latency_ms)"),
        p95_latency_ms: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)")
      })
      |> Repo.one()

    %{
      requests_total: result.request_count,
      cost_usd: Decimal.new(to_string(result.cost_usd)),
      prompt_tokens: result.prompt_tokens,
      completion_tokens: result.completion_tokens,
      cache_read_tokens: result.cache_read_tokens,
      cache_creation_tokens: result.cache_creation_tokens,
      avg_latency_ms: avg_to_float(result.avg_latency_ms),
      p95_latency_ms: avg_to_float(result.p95_latency_ms)
    }
  end

  @doc """
  Uso del día UTC por hora, desglosado por proveedor — la gráfica "Hoy por
  hora · por proveedor" del tab "En vivo".

  Devuelve las 24 horas del día (`0..23`, zero-filled, para que el eje se
  dibuje siempre) sobre la MISMA ventana que el resto de los "Hoy" del tab
  (día UTC, el que reinicia el tope global):

      %{
        hour: 0..23,
        total_requests: integer,
        total_cost_usd: Decimal.t(),
        providers: [%{provider_name: String.t(), requests: integer, cost_usd: Decimal.t()}]
      }

  `providers` va ordenado por requests desc (el frontend apila en ese
  orden). Los logs sin `provider_id` caen en "#{@no_provider}".

  Barata por diseño: **una** consulta agregada agrupada por (hora,
  proveedor) sobre la partición del día en curso, sin joins — los nombres
  de los proveedores se resuelven después, en una segunda consulta acotada
  a los ids que realmente aparecieron.
  """
  @spec today_usage_by_hour_provider() :: [map()]
  def today_usage_by_hour_provider do
    from = Tokengate.Periods.start_of_day_utc("Etc/UTC")

    bucketed =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from)
      |> select([rl], %{
        hour: fragment("CAST(EXTRACT(hour FROM ?) AS integer)", rl.inserted_at),
        provider_id: rl.provider_id,
        id: rl.id,
        cost_usd: rl.provider_cost_usd
      })
      |> subquery()

    rows =
      from(b in bucketed,
        group_by: [b.hour, b.provider_id],
        select: %{
          hour: b.hour,
          provider_id: b.provider_id,
          request_count: count(b.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", b.cost_usd)
        }
      )
      |> Repo.all()

    identities = provider_identity_by_id(rows)

    rows
    |> Enum.map(fn row ->
      identity = Map.get(identities, row.provider_id, %{name: @no_provider, logo_url: nil})

      %{
        hour: row.hour,
        provider_name: identity.name || @no_provider,
        provider_logo_url: identity.logo_url,
        requests: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd))
      }
    end)
    |> Enum.group_by(& &1.hour)
    |> then(fn by_hour ->
      for hour <- 0..23 do
        # Varios `provider_id` pueden compartir nombre (o no tener nombre):
        # se colapsan en una sola fila del desglose, como en el resto de
        # las gráficas apiladas del hub.
        providers =
          by_hour
          |> Map.get(hour, [])
          |> Enum.group_by(& &1.provider_name)
          |> Enum.map(fn {name, entries} ->
            %{
              provider_name: name,
              # El logo también se colapsa: sirve el del primer id que traiga
              # uno del catálogo.
              provider_logo_url: Enum.find_value(entries, & &1.provider_logo_url),
              requests: Enum.reduce(entries, 0, &(&1.requests + &2)),
              cost_usd:
                Enum.reduce(entries, Decimal.new(0), fn e, acc ->
                  Decimal.add(acc, e.cost_usd)
                end)
            }
          end)
          |> Enum.sort_by(& &1.requests, :desc)

        %{
          hour: hour,
          total_requests: Enum.reduce(providers, 0, &(&1.requests + &2)),
          total_cost_usd:
            Enum.reduce(providers, Decimal.new(0), fn p, acc ->
              Decimal.add(acc, p.cost_usd)
            end),
          providers: providers
        }
      end
    end)
  end

  # Identidad de cada proveedor presente en las filas agregadas (nombre y logo
  # del catálogo), en una sola consulta: el logo de models.dev viaja con la
  # misma tarjeta que el nombre, sin un lookup por proveedor.
  defp provider_identity_by_id(rows) do
    ids = rows |> Enum.map(& &1.provider_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        Tokengate.Providers.Provider
        |> where([p], p.id in ^ids)
        |> select([p], {p.id, p.name, p.logo_url})
        |> Repo.all()
        |> Map.new(fn {id, name, logo_url} -> {id, %{name: name, logo_url: logo_url}} end)
    end
  end

  defp error_rate(0, _errors), do: 0.0
  defp error_rate(total, errors), do: Float.round(errors / total * 100, 1)

  defp avg_to_float(nil), do: nil

  defp avg_to_float(%Decimal{} = d) do
    d |> Decimal.to_float() |> Float.round(1)
  end

  defp avg_to_float(n) when is_integer(n), do: Float.round(n / 1, 1)
  defp avg_to_float(n) when is_float(n), do: Float.round(n, 1)

  defp compute_avg_tps(_tokens, 0), do: nil
  defp compute_avg_tps(0, _latency), do: 0.0

  defp compute_avg_tps(tokens, latency_ms) when is_integer(tokens) and is_integer(latency_ms) do
    tokens / (latency_ms / 1000)
  end

  @doc """
  Per-user total historical spend across all group memberships.

  Returns `%{user_id => Decimal.t()}` — the sum of `provider_cost_usd`
  (the real cost) from all `request_logs`, grouped by user.
  Used by the admin users page for the "Gasto total" column.
  """
  @spec total_spend_by_user() :: %{term() => Decimal.t()}
  def total_spend_by_user do
    RequestLog
    |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
    |> group_by([_rl, tm], tm.user_id)
    |> select([rl, tm], {tm.user_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {user_id, cost} -> {user_id, Decimal.new(to_string(cost))} end)
  end

  @doc """
  Per-service total historical spend. Returns `%{service_id => Decimal.t()}`
  — the sum of `provider_cost_usd` (the real cost) from all `request_logs`
  grouped by service. Used by the admin services page for the "Gasto total"
  column. Mirror of `total_spend_by_user/0`.
  """
  @spec total_spend_by_service() :: %{term() => Decimal.t()}
  def total_spend_by_service do
    RequestLog
    |> where([rl], not is_nil(rl.service_id))
    |> group_by([rl], rl.service_id)
    |> select([rl], {rl.service_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {service_id, cost} -> {service_id, Decimal.new(to_string(cost))} end)
  end

  @doc """
  Truncates all request logs. This is a **destructive operation** that
  removes every row from `request_logs` while preserving the table
  structure and partitions.

  Returns `{0, nil}` as a sentinel (TRUNCATE does not return a row count).
  """
  @spec truncate_request_logs() :: {integer(), nil}
  def truncate_request_logs do
    Repo.query!("TRUNCATE TABLE request_logs RESTART IDENTITY CASCADE")
    {0, nil}
  end

  @doc """
  Aggregated stats for a set of group_member_ids (used by the user-detail
  stats page). Pass a list to consolidate across multiple memberships.

  Combines:
    * cost & token totals over the given range (the whole lifetime unless
      `:from`/`:to` are passed), plus a `realtime_5min` rolling window,
    * request_count and per-status-class breakdown,
    * top 5 models used (by request count, descending),
    * last request timestamp (or `nil`).

  Filters out logs with `group_member_id == nil` (services etc.).

  ## Options

    * `:from` — `inserted_at >= from` (DateTime). Optional.
    * `:to`   — `inserted_at <= to` (DateTime). Optional.
  """
  @spec member_stats(binary() | [binary()], keyword() | map()) :: map()
  def member_stats(group_member_ids, opts \\ [])
      when is_list(group_member_ids) or is_binary(group_member_ids) do
    ids = if is_binary(group_member_ids), do: [group_member_ids], else: group_member_ids

    opts_map =
      cond do
        is_map(opts) -> opts
        is_list(opts) -> Map.new(opts)
        true -> %{}
      end

    summary =
      if ids == [] do
        %{
          total_cost_usd: Decimal.new(0),
          total_prompt_tokens: 0,
          total_completion_tokens: 0,
          total_cache_read_tokens: 0,
          total_cache_creation_tokens: 0,
          request_count: 0,
          avg_latency_ms: nil,
          avg_tps: nil,
          avg_ttft_ms: nil
        }
      else
        cost_summary_for_members(ids, opts_map)
      end

    range =
      opts_map
      |> Map.take([:from, :to])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    status_class_breakdown =
      if ids == [],
        do: %{"2xx" => 0, "4xx" => 0, "5xx" => 0},
        else: status_breakdown_for_ids(ids, opts_map)

    top_models = if ids == [], do: [], else: top_models_for_ids(ids, 5, opts_map)

    last_request_at =
      if ids == [] do
        nil
      else
        RequestLog
        |> where([rl], rl.group_member_id in ^ids)
        |> apply_member_stats_range(range)
        |> select([rl], rl.inserted_at)
        |> order_by([rl], desc: rl.inserted_at)
        |> limit(1)
        |> Repo.one()
      end

    realtime_window =
      if ids == [] do
        %{request_count: 0, error_count: 0, avg_latency_ms: nil, error_rate: 0.0}
      else
        RequestLog
        |> where([rl], rl.group_member_id in ^ids)
        |> apply_member_stats_range(range)
        |> realtime_summary_for_member()
      end

    Map.merge(summary, %{
      status_breakdown: status_class_breakdown,
      top_models: top_models,
      last_request_at: last_request_at,
      realtime_5min: realtime_window
    })
  end

  defp apply_member_stats_range(query, %{from: from, to: to}) do
    query |> maybe_members_from(from) |> maybe_members_to(to)
  end

  defp apply_member_stats_range(query, _), do: query

  @doc """
  Aggregated stats for a single **user**, scoped by the durable identity
  (`request_logs.user_id`) instead of by memberships — mirror of
  `member_stats/2`. Survives membership rotation: a user whose group was
  changed keeps ALL their history in these numbers, matching what the
  credit engine debited.

  Returns the same shape as `member_stats/2`.
  """
  def user_stats(user_id, opts \\ []) when is_binary(user_id) do
    opts_map =
      cond do
        is_map(opts) -> opts
        is_list(opts) -> Map.new(opts)
        true -> %{}
      end

    range =
      opts_map
      |> Map.take([:from, :to])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    base = where(RequestLog, [rl], rl.user_id == ^user_id)

    summary =
      cost_summary(Map.merge(%{user_ids: [user_id]}, range))

    status_class_breakdown = status_breakdown_for_user(user_id, opts_map)
    top_models = top_models_for_user(user_id, 5, opts_map)

    last_request_at =
      base
      |> apply_member_stats_range(range)
      |> select([rl], rl.inserted_at)
      |> order_by([rl], desc: rl.inserted_at)
      |> limit(1)
      |> Repo.one()

    realtime_window =
      base
      |> apply_member_stats_range(range)
      |> realtime_summary_for_member()

    Map.merge(summary, %{
      status_breakdown: status_class_breakdown,
      top_models: top_models,
      last_request_at: last_request_at,
      realtime_5min: realtime_window
    })
  end

  @doc """
  Aggregated stats for a single **service** (the service-detail stats page).

  Mirror of `member_stats/2` for the service subject: a service has no
  `group_member_id` (its logs carry `service_id` and a null member id), so the
  queries filter by `service_id` instead.

  Returns the same shape as `member_stats/2`: cost & token totals, per-status
  breakdown, top 5 models, last request timestamp and a `realtime_5min` window.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime). Optional.
    * `:to`   — `inserted_at <= to` (DateTime). Optional.
  """
  @spec service_stats(binary(), keyword() | map()) :: map()
  def service_stats(service_id, opts \\ []) do
    opts_map =
      cond do
        is_map(opts) -> opts
        is_list(opts) -> Map.new(opts)
        true -> %{}
      end

    range =
      opts_map
      |> Map.take([:from, :to])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    filters = Map.merge(%{"service_id" => service_id}, range)

    last_request_at =
      RequestLog
      |> where([rl], rl.service_id == ^service_id)
      |> apply_log_filters(range)
      |> select([rl], rl.inserted_at)
      |> order_by([rl], desc: rl.inserted_at)
      |> limit(1)
      |> Repo.one()

    cost_summary(filters)
    |> Map.merge(%{
      status_breakdown: status_breakdown_for_service(service_id, range),
      top_models: top_models_for_service(service_id, 5, range),
      last_request_at: last_request_at,
      realtime_5min: realtime_summary(filters)
    })
  end

  defp status_breakdown_for_service(service_id, range) do
    empty = %{"2xx" => 0, "4xx" => 0, "5xx" => 0}

    RequestLog
    |> where([rl], rl.service_id == ^service_id)
    |> apply_log_filters(range)
    |> group_by(
      [rl],
      fragment(
        "CASE WHEN ? BETWEEN 200 AND 299 THEN '2xx'
              WHEN ? BETWEEN 400 AND 499 THEN '4xx'
              WHEN ? BETWEEN 500 AND 599 THEN '5xx'
              ELSE NULL END",
        rl.status_code,
        rl.status_code,
        rl.status_code
      )
    )
    |> select(
      [rl],
      {fragment(
         "CASE WHEN ? BETWEEN 200 AND 299 THEN '2xx'
               WHEN ? BETWEEN 400 AND 499 THEN '4xx'
               WHEN ? BETWEEN 500 AND 599 THEN '5xx'
               ELSE NULL END",
         rl.status_code,
         rl.status_code,
         rl.status_code
       ), count(rl.id)}
    )
    |> Repo.all()
    |> Enum.reduce(empty, fn {class, n}, acc -> Map.put(acc, class, n) end)
  end

  defp top_models_for_service(service_id, limit, range) do
    RequestLog
    |> where([rl], rl.service_id == ^service_id)
    |> apply_log_filters(range)
    |> group_by([rl], rl.model_requested)
    |> select([rl], %{model_requested: rl.model_requested, count: count(rl.id)})
    |> order_by(desc: :count)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  HTTP status-class breakdown (2xx/4xx/5xx) for a set of group_member_ids.
  Returns a map `%{"2xx" => n, "4xx" => n, "5xx" => n}`, with counts of 0
  for classes that never appeared.
  """
  @spec status_breakdown_for_ids([binary()], keyword() | map()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def status_breakdown_for_ids(ids, opts \\ []) do
    status_breakdown_scoped(
      where(RequestLog, [rl], rl.group_member_id in ^ids),
      opts
    )
  end

  @doc """
  Same as `status_breakdown_for_ids/2`, but scoped by **user id** — the
  durable identity (`request_logs.user_id`). Survives membership rotation.
  """
  @spec status_breakdown_for_user(binary(), keyword() | map()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def status_breakdown_for_user(user_id, opts \\ []) when is_binary(user_id) do
    status_breakdown_scoped(
      where(RequestLog, [rl], rl.user_id == ^user_id),
      opts
    )
  end

  defp status_breakdown_scoped(%Ecto.Query{} = base, opts) do
    opts_map =
      cond do
        is_map(opts) -> opts
        is_list(opts) -> Map.new(opts)
        true -> %{}
      end

    range =
      opts_map
      |> Map.take([:from, :to])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    empty = %{"2xx" => 0, "4xx" => 0, "5xx" => 0}

    base
    |> apply_member_stats_range(range)
    |> group_by([rl], fragment("CASE WHEN ? BETWEEN 200 AND 299 THEN '2xx'
                                 WHEN ? BETWEEN 400 AND 499 THEN '4xx'
                                 WHEN ? BETWEEN 500 AND 599 THEN '5xx'
                                 ELSE NULL END", rl.status_code, rl.status_code, rl.status_code))
    |> select(
      [rl],
      {fragment("CASE WHEN ? BETWEEN 200 AND 299 THEN '2xx'
                                  WHEN ? BETWEEN 400 AND 499 THEN '4xx'
                                  WHEN ? BETWEEN 500 AND 599 THEN '5xx'
                                  ELSE NULL END", rl.status_code, rl.status_code, rl.status_code),
       count(rl.id)}
    )
    |> Repo.all()
    |> Enum.reduce(empty, fn {class, n}, acc -> Map.put(acc, class, n) end)
  end

  @doc """
  Top-N most-requested models for a set of group_member_ids. Returns a
  list of `%{model_requested, count}` sorted descending.
  """
  @spec top_models_for_ids([binary()], pos_integer(), keyword() | map()) :: [
          %{required(atom()) => term()}
        ]
  def top_models_for_ids(ids, limit, opts \\ []) do
    top_models_scoped(
      where(RequestLog, [rl], rl.group_member_id in ^ids),
      limit,
      opts
    )
  end

  @doc """
  Same as `top_models_for_ids/3`, but scoped by **user id** — the durable
  identity (`request_logs.user_id`). Survives membership rotation.
  """
  @spec top_models_for_user(binary(), pos_integer(), keyword() | map()) :: [
          %{required(atom()) => term()}
        ]
  def top_models_for_user(user_id, limit, opts \\ []) when is_binary(user_id) do
    top_models_scoped(
      where(RequestLog, [rl], rl.user_id == ^user_id),
      limit,
      opts
    )
  end

  defp top_models_scoped(%Ecto.Query{} = base, limit, opts) do
    opts_map =
      cond do
        is_map(opts) -> opts
        is_list(opts) -> Map.new(opts)
        true -> %{}
      end

    range =
      opts_map
      |> Map.take([:from, :to])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    base
    |> apply_member_stats_range(range)
    |> group_by([rl], rl.model_requested)
    |> select([rl], %{
      model_requested: rl.model_requested,
      count: count(rl.id)
    })
    |> order_by(desc: :count)
    |> limit(^limit)
    |> Repo.all()
  end

  defp realtime_summary_for_member(query) do
    cutoff =
      DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

    result =
      query
      |> where([rl], rl.inserted_at >= ^cutoff)
      |> select([rl], %{
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE status_code >= 400)"),
        avg_latency_ms: fragment("AVG(latency_ms)")
      })
      |> Repo.one()

    %{
      request_count: result.request_count,
      error_count: result.error_count,
      avg_latency_ms: avg_to_float(result.avg_latency_ms),
      error_rate: error_rate(result.request_count, result.error_count)
    }
  end
end
