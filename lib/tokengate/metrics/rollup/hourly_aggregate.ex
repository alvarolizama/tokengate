defmodule Tokengate.Metrics.Rollup.HourlyAggregate do
  @moduledoc """
  Writes the hourly metrics rollup (`request_metrics_hourly`) from
  `request_logs`.

  The single entry point is `aggregate_hours/1`: for a UTC hour range, it
  groups `request_logs` by `(hour, team_member_id, model_alias_id,
  provider_id)` and upserts the sums into the rollup table. Because each
  hour is **fully re-aggregated** (not incremented), the operation is
  idempotent: late-arriving logs, corrected rows, or a crashed run simply
  converge on the next execution.

  Read paths live in `Tokengate.Metrics.Rollup` (`hourly_series_from_rollup/2`,
  `summary_from_rollup/2`, `top_errors_from_rollup/2`).

  ## Cost precision

  `provider_cost_usd` (Decimal) is stored as integer micro-USD
  (`ROUND(usd * 1_000_000)`). Summing integers is exact; converting back
  is a single `Decimal` division per display value. The rounding error is
  bounded by 1 micro-dollar per hour-bucket-dimension, far below any
  display precision the dashboards use (6+ decimals).
  """

  import Ecto.Query, warn: false

  alias Tokengate.Repo

  @doc """
  Re-aggregates the UTC hours covered by `[from, to)` into
  `request_metrics_hourly`.

  `from` and `to` must be UTC `DateTime`s; the range is clamped to whole
  hours (`date_trunc('hour', ...)`). Each execution re-writes the complete
  content of every touched hour bucket, so results converge regardless of
  run order or repetition.

  Returns `{:ok, rows_written}` with the Postgres command tag row count
  (rows inserted + updated).
  """
  @spec aggregate_hours(DateTime.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  def aggregate_hours(from, to) when is_struct(from, DateTime) and is_struct(to, DateTime) do
    from = DateTime.truncate(from, :second)
    to = DateTime.truncate(to, :second)

    sql = """
    WITH bucketed AS (
      SELECT
        date_trunc('hour', rl.inserted_at) AS hour_utc,
        rl.team_member_id,
        rl.model_alias_id,
        rl.provider_id,
        rl.status_code,
        rl.prompt_tokens,
        rl.completion_tokens,
        rl.cache_read_tokens,
        rl.cache_creation_tokens,
        rl.provider_cost_usd,
        rl.latency_ms
      FROM request_logs rl
      WHERE rl.inserted_at >= $1 AND rl.inserted_at < $2
    )
    INSERT INTO request_metrics_hourly
      (id, day, hour_utc, team_member_id, model_alias_id, provider_id,
       request_count, error_count, prompt_tokens, completion_tokens,
       cache_read_tokens, cache_creation_tokens, cost_micro,
       total_latency_ms, latency_count, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      b.hour_utc::date,
      b.hour_utc,
      b.team_member_id,
      b.model_alias_id,
      b.provider_id,
      COUNT(*),
      COUNT(*) FILTER (WHERE b.status_code >= 400),
      COALESCE(SUM(b.prompt_tokens), 0)::bigint,
      COALESCE(SUM(b.completion_tokens), 0)::bigint,
      COALESCE(SUM(b.cache_read_tokens), 0)::bigint,
      COALESCE(SUM(b.cache_creation_tokens), 0)::bigint,
      COALESCE(SUM(ROUND(b.provider_cost_usd * 1000000)), 0)::bigint,
      COALESCE(SUM(b.latency_ms), 0)::bigint,
      COUNT(b.latency_ms),
      now(),
      now()
    FROM bucketed b
    GROUP BY b.hour_utc, b.team_member_id, b.model_alias_id, b.provider_id
    ON CONFLICT (day, hour_utc, team_member_id, model_alias_id, provider_id)
    DO UPDATE SET
      request_count = EXCLUDED.request_count,
      error_count = EXCLUDED.error_count,
      prompt_tokens = EXCLUDED.prompt_tokens,
      completion_tokens = EXCLUDED.completion_tokens,
      cache_read_tokens = EXCLUDED.cache_read_tokens,
      cache_creation_tokens = EXCLUDED.cache_creation_tokens,
      cost_micro = EXCLUDED.cost_micro,
      total_latency_ms = EXCLUDED.total_latency_ms,
      latency_count = EXCLUDED.latency_count,
      updated_at = now()
    """

    result = Repo.query!(sql, [from, to])
    {:ok, result.num_rows}
  end

  @doc """
  Backfills the rollup for every UTC hour between `from` and `to` (or up
  to `Date.utc_today()` when omitted), one day at a time to keep each
  transaction bounded.

  Returns `{:ok, %{days: n, rows: total_rows}}`.

  Safe to re-run: every hour is re-aggregated with upserts. For a first
  production backfill over millions of `request_logs` rows, run inside
  `iex` and watch the day counters (each day is its own statement — a
  failed day does not lose the progress of previous days).
  """
  @spec backfill(DateTime.t(), DateTime.t() | nil) ::
          {:ok, %{days: non_neg_integer(), rows: non_neg_integer()}}
  def backfill(from, to \\ nil) when is_struct(from, DateTime) do
    to = to || DateTime.new!(Date.utc_today() |> Date.add(1), ~T[00:00:00], "Etc/UTC")

    from_day = DateTime.to_date(from)
    to_day = DateTime.to_date(to)

    # aggregate_hours/2 uses Repo.query! — a failing day raises (and aborts
    # the backfill); previous days' upserts are already committed, so a
    # re-run simply resumes.
    {days, rows} =
      from_day
      |> Date.range(to_day)
      |> Enum.map(fn day ->
        day_from = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")

        day_to =
          DateTime.new!(Date.add(day, 1), ~T[00:00:00], "Etc/UTC")
          |> min_dt(to)

        {:ok, rows} = aggregate_hours(day_from, day_to)
        rows
      end)
      |> Enum.reduce({0, 0}, fn rows, {d, r} -> {d + 1, r + rows} end)

    {:ok, %{days: days, rows: rows}}
  end

  defp min_dt(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
end
