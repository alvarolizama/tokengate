defmodule Tokengate.Logs do
  @moduledoc """
  The Logs context: append-only request log entries.

  This context only **inserts** and **queries** request logs — never updates
  or deletes. The `request_logs` table is a native Postgres RANGE-partitioned
  table on `inserted_at` (daily granularity).

  ## Privacy

  This table **never** stores prompt or completion content — only metadata
  (token counts, costs, latency, status). No PII or request/response bodies
  are persisted here.
  """

  import Ecto.Query, warn: false

  alias Tokengate.Repo
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Accounts.TeamMember

  @default_limit 50
  @max_limit 500

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
    * `:team_member_id` — exact match
    * `:team_member_ids` — list of allowed team_member ids (OR)
    * `:team_id` — exact match, joined through `team_members`
    * `:provider_id` — exact match
    * `:model_alias_id` — exact match
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
    |> preload(team_member: [:user, :team])
    |> preload(:provider)
    |> Repo.all()
  end

  @doc """
  Lists request logs with `inserted_at` strictly after `since` (DateTime),
  ordered newest-first. Used by the LogsLive real-time subscription to
  fetch new logs appended after page load.

  Same filter support as `list_logs/1` (scope, status, agent, etc.), but
  the `before` cursor is ignored. A defensive `limit` caps how many new
  logs are returned in a single real-time refresh (default 500).
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
    |> preload(team_member: [:user, :team])
    |> preload(:provider)
    |> Repo.all()
  end

  @doc """
  Lists request logs for a specific team, joining through `team_members`.

  Filters are the same as `list_logs/1`.
  """
  def list_logs_for_team(team_id, filters \\ %{}) do
    limit = clamp_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    RequestLog
    |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
    |> where([rl, tm], tm.team_id == ^team_id)
    |> apply_log_filters(filters)
    |> order_by([rl], desc: rl.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp apply_log_filters(query, filters) do
    query
    |> maybe_where(:team_member_id, filters)
    |> maybe_where_member_ids(filters)
    |> maybe_where_team_id(filters)
    |> maybe_where(:provider_id, filters)
    |> maybe_where(:model_alias_id, filters)
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

  # Filter by team_id through the team_members join. When team_id is present we
  # INNER JOIN team_members so the WHERE references both bindings.
  defp maybe_where_team_id(query, filters) do
    value = Map.get(filters, :team_id) || Map.get(filters, "team_id")

    case value do
      nil ->
        query

      team_id ->
        tm =
          TeamMember
          |> where([tm], tm.team_id == ^team_id)
          |> select([tm], tm.id)

        where(query, [rl], rl.team_member_id in subquery(tm))
    end
  end

  defp maybe_where(query, field, filters) do
    value = Map.get(filters, field)
    value = if is_nil(value), do: Map.get(filters, to_string(field)), else: value

    if is_nil(value), do: query, else: where(query, [rl], field(rl, ^field) == ^value)
  end

  defp maybe_where_member_ids(query, filters) do
    value = Map.get(filters, :team_member_ids) || Map.get(filters, "team_member_ids")

    case value do
      nil -> query
      ids when is_list(ids) -> where(query, [rl], rl.team_member_id in ^ids)
    end
  end

  defp maybe_status_class(query, filters) do
    case Map.get(filters, :status_class) || Map.get(filters, "status_class") do
      nil -> query
      "" -> query
      "2xx" -> where(query, [rl], rl.status_code >= 200 and rl.status_code < 300)
      "4xx" -> where(query, [rl], rl.status_code >= 400 and rl.status_code < 500)
      "5xx" -> where(query, [rl], rl.status_code >= 500 and rl.status_code < 600)
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

  defp clamp_limit(nil), do: @default_limit

  defp clamp_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @max_limit)
  end

  defp clamp_limit(_), do: @default_limit

  # ---------------------------------------------------------------------------
  # Aggregates
  # ---------------------------------------------------------------------------

  @doc """
  Computes a cost summary over request logs for a specific team, joining
  through `team_members`.

  Returns the same shape as `cost_summary/1`:
    * `:total_cost_usd`
    * `:total_provider_cost_usd`
    * `:total_savings_usd`
    * `:total_estimated_cost_usd`
    * `:total_prompt_tokens`
    * `:total_completion_tokens`
    * `:request_count`

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  def cost_summary_for_team(team_id, opts \\ %{}) do
    from = Map.get(opts, :from)
    to = Map.get(opts, :to)

    query =
      RequestLog
      |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
      |> where([rl, tm], tm.team_id == ^team_id)
      |> maybe_team_from(from)
      |> maybe_team_to(to)
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

  defp maybe_team_from(query, nil), do: query
  defp maybe_team_from(query, from), do: where(query, [rl], rl.inserted_at >= ^from)

  defp maybe_team_to(query, nil), do: query
  defp maybe_team_to(query, to), do: where(query, [rl], rl.inserted_at <= ^to)

  @doc """
  Computes a cost summary over request logs for a specific set of team
  members (by their ids).

  Returns the same shape as `cost_summary/1`. Used by the dashboard for
  the "user" scope (a user's own consumption across all their memberships).

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  def cost_summary_for_members(team_member_ids, opts \\ %{})

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

  def cost_summary_for_members(team_member_ids, opts) when is_list(team_member_ids) do
    from = Map.get(opts, :from)
    to = Map.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.team_member_id in ^team_member_ids)
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
    * `:total_provider_cost_usd`
    * `:total_savings_usd`
    * `:total_estimated_cost_usd`
    * `:total_prompt_tokens`
    * `:total_completion_tokens`
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
  Per-user total historical spend across all team memberships.

  Returns `%{user_id => Decimal.t()}` — the sum of `provider_cost_usd`
  (the real cost) from all `request_logs`, grouped by user.
  Used by the admin users page for the "Gasto total" column.
  """
  @spec total_spend_by_user() :: %{term() => Decimal.t()}
  def total_spend_by_user do
    RequestLog
    |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
    |> group_by([_rl, tm], tm.user_id)
    |> select([rl, tm], {tm.user_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {user_id, cost} -> {user_id, Decimal.new(to_string(cost))} end)
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
  Aggregated stats for a set of team_member_ids (used by the user-detail
  stats page). Pass a list to consolidate across multiple memberships.

  Combines:
    * lifetime + 5d/30d cost & token totals (5d/30d via `:from` opts),
    * request_count and per-status-class breakdown,
    * top 5 models used (by request count, descending),
    * last request timestamp (or `nil`),
    * avg latency / avg tps / avg ttft over the lifetime of the member.

  Filters out logs with `team_member_id == nil` (services etc.).

  ## Options

    * `:from` — `inserted_at >= from` (DateTime). Optional.
    * `:to`   — `inserted_at <= to` (DateTime). Optional.
  """
  @spec member_stats(binary() | [binary()], keyword() | map()) :: map()
  def member_stats(team_member_ids, opts \\ [])
      when is_list(team_member_ids) or is_binary(team_member_ids) do
    ids = if is_binary(team_member_ids), do: [team_member_ids], else: team_member_ids

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
        |> where([rl], rl.team_member_id in ^ids)
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
        |> where([rl], rl.team_member_id in ^ids)
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
  HTTP status-class breakdown (2xx/4xx/5xx) for a set of team_member_ids.
  Returns a map `%{"2xx" => n, "4xx" => n, "5xx" => n}`, with counts of 0
  for classes that never appeared.
  """
  @spec status_breakdown_for_ids([binary()], keyword() | map()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def status_breakdown_for_ids(ids, opts \\ []) do
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

    RequestLog
    |> where([rl], rl.team_member_id in ^ids)
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
  Top-N most-requested models for a set of team_member_ids. Returns a
  list of `%{model_requested, count}` sorted descending.
  """
  @spec top_models_for_ids([binary()], pos_integer(), keyword() | map()) :: [
          %{required(atom()) => term()}
        ]
  def top_models_for_ids(ids, limit, opts \\ []) do
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

    RequestLog
    |> where([rl], rl.team_member_id in ^ids)
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
