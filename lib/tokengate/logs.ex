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
  the `before` cursor and `limit` are ignored — all new logs are returned.
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

    RequestLog
    |> apply_log_filters(filters)
    |> order_by([rl], desc: rl.inserted_at)
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
    |> maybe_where(:provider_id, filters)
    |> maybe_where(:model_alias_id, filters)
    |> maybe_where(:agent_type, filters)
    |> maybe_where(:status_code, filters)
    |> maybe_status_class(filters)
    |> maybe_model_search(filters)
    |> maybe_where(:streaming, filters)
    |> maybe_from(filters)
    |> maybe_to(filters)
    |> maybe_before(filters)
    |> maybe_after(filters)
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
        total_cost_usd: fragment("COALESCE(SUM(cost_usd), 0)"),
        total_provider_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)"),
        total_savings_usd: fragment("COALESCE(SUM(savings_usd), 0)"),
        total_estimated_cost_usd: fragment("COALESCE(SUM(estimated_cost_usd), 0)"),
        total_prompt_tokens: coalesce(sum(rl.prompt_tokens), 0),
        total_completion_tokens: coalesce(sum(rl.completion_tokens), 0),
        request_count: count(rl.id)
      })

    result = Repo.one(query)

    %{
      total_cost_usd: Decimal.new(to_string(result.total_cost_usd)),
      total_provider_cost_usd: Decimal.new(to_string(result.total_provider_cost_usd)),
      total_savings_usd: Decimal.new(to_string(result.total_savings_usd)),
      total_estimated_cost_usd: Decimal.new(to_string(result.total_estimated_cost_usd)),
      total_prompt_tokens: result.total_prompt_tokens,
      total_completion_tokens: result.total_completion_tokens,
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
      total_provider_cost_usd: Decimal.new(0),
      total_savings_usd: Decimal.new(0),
      total_estimated_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
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
        total_cost_usd: fragment("COALESCE(SUM(cost_usd), 0)"),
        total_provider_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)"),
        total_savings_usd: fragment("COALESCE(SUM(savings_usd), 0)"),
        total_estimated_cost_usd: fragment("COALESCE(SUM(estimated_cost_usd), 0)"),
        total_prompt_tokens: coalesce(sum(rl.prompt_tokens), 0),
        total_completion_tokens: coalesce(sum(rl.completion_tokens), 0),
        request_count: count(rl.id)
      })

    result = Repo.one(query)

    %{
      total_cost_usd: Decimal.new(to_string(result.total_cost_usd)),
      total_provider_cost_usd: Decimal.new(to_string(result.total_provider_cost_usd)),
      total_savings_usd: Decimal.new(to_string(result.total_savings_usd)),
      total_estimated_cost_usd: Decimal.new(to_string(result.total_estimated_cost_usd)),
      total_prompt_tokens: result.total_prompt_tokens,
      total_completion_tokens: result.total_completion_tokens,
      request_count: result.request_count
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
        total_cost_usd: fragment("COALESCE(SUM(cost_usd), 0)"),
        total_provider_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)"),
        total_savings_usd: fragment("COALESCE(SUM(savings_usd), 0)"),
        total_estimated_cost_usd: fragment("COALESCE(SUM(estimated_cost_usd), 0)"),
        total_prompt_tokens: coalesce(sum(rl.prompt_tokens), 0),
        total_completion_tokens: coalesce(sum(rl.completion_tokens), 0),
        request_count: count(rl.id),
        total_latency_ms: fragment("COALESCE(SUM(latency_ms), 0)"),
        avg_latency_ms: fragment("AVG(latency_ms)"),
        avg_ttft_ms: fragment("AVG(ttft_ms)")
      })
      |> Repo.one()

    %{
      total_cost_usd: Decimal.new(to_string(result.total_cost_usd)),
      total_provider_cost_usd: Decimal.new(to_string(result.total_provider_cost_usd)),
      total_savings_usd: Decimal.new(to_string(result.total_savings_usd)),
      total_estimated_cost_usd: Decimal.new(to_string(result.total_estimated_cost_usd)),
      total_prompt_tokens: result.total_prompt_tokens,
      total_completion_tokens: result.total_completion_tokens,
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
end
