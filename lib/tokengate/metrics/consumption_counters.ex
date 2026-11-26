defmodule Tokengate.Metrics.ConsumptionCounters do
  @moduledoc """
  Maintenance surface for the durable consumption counters
  (`consumption_counters`, `topup_consumption_counters`).

  The counters are kept exact by the `request_logs` trigger, so under normal
  operation nothing here is needed. These are the escape hatches:

    * `backfill/0` — (re)builds the counters from the raw logs the retention
      still holds. Every write is MONOTONE (`GREATEST`): the backfill can raise
      a bucket to the truth but never lower it, so a snapshot taken while a
      late row is still being flushed cannot erase real spend. Today's bucket is
      never touched (the trigger is adding up there right now). All three
      statements run in one transaction, so a failure cannot leave the counters
      half-populated while `populated?/0` already calls them authoritative.
    * `mismatches/1` — the comparison the owner asked for: counter vs the same
      aggregate computed with a query over the logs, exact in integer micro-USD.
    * `topup_mismatches/1` — the same comparison for the money table
      (`topup_consumption_counters`), which drives `remaining_usd`.

  The log sum is the reference: `provider_cost_usd` is `numeric(12,6)`, so
  `ROUND(usd * 1_000_000)` per row is lossless and the two sides must match to
  the micro-dollar, with no tolerance.

  Only days the retention still holds can be compared: the counters cover the
  LIFETIME, so a bucket older than the oldest raw log is expected to have no
  raw counterpart and is not drift. Both sides are bounded by that range.
  """

  import Ecto.Query

  alias Tokengate.Metrics.ConsumptionCounter
  alias Tokengate.Repo

  @doc """
  Total spend per subject, straight from the durable counters.

  One index range over `consumption_counters` (one row per subject per day)
  instead of `SUM(provider_cost_usd)` over every retained partition: the
  lifetime totals were the last aggregates that grew with history.

  Returns `%{subject_id => Decimal.t()}`.
  """
  def spend_by_subject(kind) when kind in [:user, :service] do
    field = if kind == :user, do: :user_id, else: :service_id

    Repo.all(
      from(c in ConsumptionCounter,
        where: not is_nil(field(c, ^field)),
        group_by: field(c, ^field),
        select: {field(c, ^field), fragment("COALESCE(SUM(?), 0)::bigint", c.spend_micro)}
      )
    )
    |> Map.new(fn {id, micro} -> {id, micro_to_usd(micro)} end)
  end

  @doc """
  Average latency and TTFT per subject, straight from the durable counters.

  `SUM` + `COUNT` rebuild the exact `AVG()` over any range of days, and the
  counters keep the lifetime — so speed metrics answer for days the raw
  partitions no longer hold. Percentiles are NOT available: no histogram is
  stored, only sum and count.

  Returns `%{subject_id => %{avg_latency_ms, avg_ttft_ms, latency_samples,
  ttft_samples}}`; the averages are `nil` when there are no samples (which is
  what `AVG()` does too, rather than reporting a zero).
  """
  def speed_by_subject(kind) when kind in [:user, :service] do
    field = if kind == :user, do: :user_id, else: :service_id

    Repo.all(
      from(c in ConsumptionCounter,
        where: not is_nil(field(c, ^field)),
        group_by: field(c, ^field),
        select:
          {field(c, ^field), fragment("COALESCE(SUM(?), 0)::bigint", c.total_latency_ms),
           fragment("COALESCE(SUM(?), 0)::bigint", c.latency_count),
           fragment("COALESCE(SUM(?), 0)::bigint", c.total_ttft_ms),
           fragment("COALESCE(SUM(?), 0)::bigint", c.ttft_count)}
      )
    )
    |> Map.new(fn {id, latency_sum, latency_n, ttft_sum, ttft_n} ->
      {id,
       %{
         avg_latency_ms: average(latency_sum, latency_n),
         avg_ttft_ms: average(ttft_sum, ttft_n),
         latency_samples: latency_n,
         ttft_samples: ttft_n
       }}
    end)
  end

  defp average(_sum, 0), do: nil
  defp average(sum, count), do: Float.round(sum / count, 1)

  @doc """
  True when the counters hold at least one row — the guard the readers use
  before trusting them (a deployment that has not backfilled yet keeps reading
  the raw aggregates).
  """
  def populated? do
    Repo.exists?(from c in ConsumptionCounter, select: 1, limit: 1)
  end

  @doc "micro-USD → USD, same 6 decimals `numeric(12,6)` stores."
  def micro_to_usd(micro) when is_integer(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
    |> Decimal.round(6, :half_up)
  end

  @doc """
  Re-aggregates every closed day from `request_logs` into the counters.

  Monotone per column (`GREATEST`), so re-running is harmless and a concurrent
  trigger bump the snapshot missed survives. All three statements share one
  transaction: either every axis is written or none is.

  Returns `{:ok, %{user_rows: n, service_rows: n, topup_rows: n}}` with the
  number of buckets written per axis.
  """
  def backfill do
    Repo.transaction(fn ->
      user_rows = Repo.query!(user_backfill_sql()).num_rows
      service_rows = Repo.query!(service_backfill_sql()).num_rows
      topup_rows = Repo.query!(topup_backfill_sql()).num_rows

      %{user_rows: user_rows, service_rows: service_rows, topup_rows: topup_rows}
    end)
  end

  @doc """
  Subject-days whose counter differs from the raw aggregate, per axis.

  `kind` is `:user` or `:service`; every row carries both sides (`counter_micro`
  and `raw_micro`) plus request/error counts, so a difference is diagnosable
  without another query. Bounded by `limit` (default 100) and to the day range
  the raw logs still cover — older counter buckets are expected history, not
  drift.
  """
  def mismatches(kind \\ :user, limit \\ 100)

  def mismatches(:user, limit) do
    Repo.query!(mismatch_sql(:user, limit)).rows
    |> Enum.map(&mismatch_row(&1, :user))
  end

  def mismatches(:service, limit) do
    Repo.query!(mismatch_sql(:service, limit)).rows
    |> Enum.map(&mismatch_row(&1, :service))
  end

  @doc """
  Top-ups whose counter differs from the raw aggregate.

  Only top-ups whose whole history still sits inside the retention window can be
  compared for equality: for an older top-up the counter is legitimately HIGHER
  than the surviving logs (that is the whole point of a durable counter).

  Each row carries `reason`: `:differs` (both sides present, values disagree) or
  `:missing_counter` (logs exist, no counter row — pre-backfill or drift).
  """
  def topup_mismatches(limit \\ 100) do
    Repo.query!(topup_mismatch_sql(limit)).rows
    |> Enum.map(&topup_mismatch_row/1)
  end

  @doc """
  Top-ups whose counter UNDER-reports the surviving logs: the one direction a
  durable money counter must never drift, whatever the top-up's age. Includes
  top-ups already deleted from `credit_topups` only through their logs, so this
  reads both sides without a join on the parent row.
  """
  def topup_underreported(limit \\ 100) do
    Repo.query!(topup_underreported_sql(limit)).rows
    |> Enum.map(&topup_mismatch_row/1)
  end

  @doc """
  Runs every comparison and reports.

  `{:ok, %{user: [...], service: [...], topups: [...], topups_underreported: [...]}}`
  """
  def reconcile(limit \\ 100) do
    {:ok,
     %{
       user: mismatches(:user, limit),
       service: mismatches(:service, limit),
       topups: topup_mismatches(limit),
       topups_underreported: topup_underreported(limit)
     }}
  end

  defp mismatch_row(
         [
           day,
           subject_id,
           counter_micro,
           raw_micro,
           counter_requests,
           raw_requests,
           counter_errors,
           raw_errors
         ],
         kind
       ) do
    %{
      kind: kind,
      day: day,
      subject_id: to_uuid(subject_id),
      counter_micro: to_int(counter_micro),
      raw_micro: to_int(raw_micro),
      counter_requests: to_int(counter_requests),
      raw_requests: to_int(raw_requests),
      counter_errors: to_int(counter_errors),
      raw_errors: to_int(raw_errors)
    }
  end

  defp topup_mismatch_row([topup_id, counter_micro, raw_micro, counter_requests, raw_requests]) do
    %{
      topup_id: to_uuid(topup_id),
      counter_micro: to_int(counter_micro),
      raw_micro: to_int(raw_micro),
      counter_requests: to_int(counter_requests),
      raw_requests: to_int(raw_requests)
    }
  end

  # `Repo.query!` returns Postgres wire values: a uuid arrives as a 16-byte
  # binary, which would print as `<<197, 208, ...>>` in the CLI report.
  defp to_uuid(nil), do: nil

  defp to_uuid(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp to_int(nil), do: nil
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)

  # ---------------------------------------------------------------------------
  # SQL — the same aggregation the trigger performs, one shot per axis
  # ---------------------------------------------------------------------------

  # `date_trunc('day', now())` bounds every statement to CLOSED days: today's
  # bucket is live (the trigger is bumping it), so overwriting it from a
  # snapshot would lose the rows committed after the snapshot.
  #
  # `GREATEST(c.x, EXCLUDED.x)` instead of a plain REPLACE: a row can land in a
  # closed day AFTER the snapshot (the log carries the request START time and
  # the write queue flushes late, or Oban retries hours later). A REPLACE would
  # overwrite the trigger's correct bump with the older snapshot and lose that
  # spend for good.
  defp user_backfill_sql do
    """
    INSERT INTO consumption_counters AS c
      (user_id, day, request_count, error_count, spend_micro, limit_spend_micro,
       prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens,
       total_latency_ms, latency_count, total_ttft_ms, ttft_count)
    SELECT rl.user_id,
           rl.inserted_at::date,
           count(*),
           count(*) FILTER (WHERE rl.status_code >= 400),
           COALESCE(SUM(ROUND(rl.provider_cost_usd * 1000000)), 0)::bigint,
           COALESCE(
             SUM(ROUND(rl.provider_cost_usd * 1000000)) FILTER (WHERE rl.credit_topup_id IS NULL),
             0
           )::bigint,
           COALESCE(SUM(rl.prompt_tokens), 0),
           COALESCE(SUM(rl.completion_tokens), 0),
           COALESCE(SUM(rl.cache_read_tokens), 0),
           COALESCE(SUM(rl.cache_creation_tokens), 0),
           -- SUM + count of the non-NULLs: `count(col)` mirrors what AVG()
           -- uses as its divisor, so the average rebuilds exactly.
           COALESCE(SUM(rl.latency_ms), 0)::bigint,
           count(rl.latency_ms)::bigint,
           COALESCE(SUM(rl.ttft_ms), 0)::bigint,
           count(rl.ttft_ms)::bigint
    FROM request_logs rl
    WHERE rl.user_id IS NOT NULL
      AND rl.inserted_at < date_trunc('day', now() AT TIME ZONE 'utc')
    GROUP BY 1, 2
    ON CONFLICT (user_id, day) WHERE user_id IS NOT NULL DO UPDATE SET
      request_count         = GREATEST(c.request_count,         EXCLUDED.request_count),
      error_count           = GREATEST(c.error_count,           EXCLUDED.error_count),
      spend_micro           = GREATEST(c.spend_micro,           EXCLUDED.spend_micro),
      limit_spend_micro     = GREATEST(c.limit_spend_micro,     EXCLUDED.limit_spend_micro),
      prompt_tokens         = GREATEST(c.prompt_tokens,         EXCLUDED.prompt_tokens),
      completion_tokens     = GREATEST(c.completion_tokens,     EXCLUDED.completion_tokens),
      cache_read_tokens     = GREATEST(c.cache_read_tokens,     EXCLUDED.cache_read_tokens),
      cache_creation_tokens = GREATEST(c.cache_creation_tokens, EXCLUDED.cache_creation_tokens),
      total_latency_ms      = GREATEST(c.total_latency_ms,      EXCLUDED.total_latency_ms),
      latency_count         = GREATEST(c.latency_count,         EXCLUDED.latency_count),
      total_ttft_ms         = GREATEST(c.total_ttft_ms,         EXCLUDED.total_ttft_ms),
      ttft_count            = GREATEST(c.ttft_count,            EXCLUDED.ttft_count),
      updated_at            = (now() AT TIME ZONE 'utc')
    """
  end

  defp service_backfill_sql do
    """
    INSERT INTO consumption_counters AS c
      (service_id, day, request_count, error_count, spend_micro, limit_spend_micro,
       prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens,
       total_latency_ms, latency_count, total_ttft_ms, ttft_count)
    SELECT rl.service_id,
           rl.inserted_at::date,
           count(*),
           count(*) FILTER (WHERE rl.status_code >= 400),
           COALESCE(SUM(ROUND(rl.provider_cost_usd * 1000000)), 0)::bigint,
           COALESCE(
             SUM(ROUND(rl.provider_cost_usd * 1000000)) FILTER (WHERE rl.credit_topup_id IS NULL),
             0
           )::bigint,
           COALESCE(SUM(rl.prompt_tokens), 0),
           COALESCE(SUM(rl.completion_tokens), 0),
           COALESCE(SUM(rl.cache_read_tokens), 0),
           COALESCE(SUM(rl.cache_creation_tokens), 0),
           COALESCE(SUM(rl.latency_ms), 0)::bigint,
           count(rl.latency_ms)::bigint,
           COALESCE(SUM(rl.ttft_ms), 0)::bigint,
           count(rl.ttft_ms)::bigint
    FROM request_logs rl
    WHERE rl.service_id IS NOT NULL
      AND rl.inserted_at < date_trunc('day', now() AT TIME ZONE 'utc')
    GROUP BY 1, 2
    ON CONFLICT (service_id, day) WHERE service_id IS NOT NULL DO UPDATE SET
      request_count         = GREATEST(c.request_count,         EXCLUDED.request_count),
      error_count           = GREATEST(c.error_count,           EXCLUDED.error_count),
      spend_micro           = GREATEST(c.spend_micro,           EXCLUDED.spend_micro),
      limit_spend_micro     = GREATEST(c.limit_spend_micro,     EXCLUDED.limit_spend_micro),
      prompt_tokens         = GREATEST(c.prompt_tokens,         EXCLUDED.prompt_tokens),
      completion_tokens     = GREATEST(c.completion_tokens,     EXCLUDED.completion_tokens),
      cache_read_tokens     = GREATEST(c.cache_read_tokens,     EXCLUDED.cache_read_tokens),
      cache_creation_tokens = GREATEST(c.cache_creation_tokens, EXCLUDED.cache_creation_tokens),
      total_latency_ms      = GREATEST(c.total_latency_ms,      EXCLUDED.total_latency_ms),
      latency_count         = GREATEST(c.latency_count,         EXCLUDED.latency_count),
      total_ttft_ms         = GREATEST(c.total_ttft_ms,         EXCLUDED.total_ttft_ms),
      ttft_count            = GREATEST(c.ttft_count,            EXCLUDED.ttft_count),
      updated_at            = (now() AT TIME ZONE 'utc')
    """
  end

  # Money must never go DOWN, and the insert must not fire for a top-up that no
  # longer exists: `request_logs` has no FK on `credit_topup_id` on purpose (the
  # historical attribution survives the deletion), while
  # `topup_consumption_counters` does — so a late log for a deleted top-up would
  # abort the whole log insert on a foreign-key violation.
  defp topup_backfill_sql do
    """
    INSERT INTO topup_consumption_counters AS t (topup_id, consumed_micro, request_count)
    SELECT rl.credit_topup_id,
           COALESCE(SUM(ROUND(rl.provider_cost_usd * 1000000)), 0)::bigint,
           count(*)
    FROM request_logs rl
    WHERE rl.credit_topup_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM credit_topups cp WHERE cp.id = rl.credit_topup_id)
    GROUP BY 1
    ON CONFLICT (topup_id) DO UPDATE SET
      consumed_micro = GREATEST(t.consumed_micro, EXCLUDED.consumed_micro),
      request_count  = GREATEST(t.request_count, EXCLUDED.request_count),
      updated_at     = (now() AT TIME ZONE 'utc')
    """
  end

  # Full outer join so a bucket present on ONE side only also shows up: a
  # missing counter row (drift after a manual import) is exactly the case a
  # plain join would hide. Comparison is a row `IS DISTINCT FROM`, which is
  # null-safe and needs no sentinel value (a legitimate -1 micro bucket would
  # collide with one).
  #
  # `counted` is bounded to `>= min(raw.day)`: the counters keep the lifetime,
  # so a bucket older than the oldest surviving log is expected history, not
  # drift. Today's bucket is excluded on both sides (the trigger owns it).
  defp mismatch_sql(:user, limit) do
    """
    WITH raw AS (
      SELECT rl.inserted_at::date AS day,
             rl.user_id,
             count(*) AS request_count,
             count(*) FILTER (WHERE rl.status_code >= 400) AS error_count,
             COALESCE(SUM(ROUND(rl.provider_cost_usd * 1000000)), 0)::bigint AS spend_micro
      FROM request_logs rl
      WHERE rl.user_id IS NOT NULL
        AND rl.inserted_at < date_trunc('day', now() AT TIME ZONE 'utc')
      GROUP BY 1, 2
    ), counted AS (
      SELECT c.day, c.user_id, c.request_count, c.error_count, c.spend_micro
      FROM consumption_counters c
      WHERE c.user_id IS NOT NULL
        AND c.day < (now() AT TIME ZONE 'utc')::date
        AND c.day >= (SELECT min(day) FROM raw)
    )
    SELECT COALESCE(raw.day, counted.day),
           COALESCE(raw.user_id, counted.user_id),
           counted.spend_micro,
           raw.spend_micro,
           counted.request_count,
           raw.request_count,
           counted.error_count,
           raw.error_count
    FROM raw
    FULL OUTER JOIN counted ON raw.day = counted.day AND raw.user_id = counted.user_id
    WHERE (counted.spend_micro, counted.request_count, counted.error_count)
          IS DISTINCT FROM
          (raw.spend_micro, raw.request_count, raw.error_count)
    ORDER BY 1 ASC
    LIMIT #{Integer.to_string(limit)}
    """
  end

  defp mismatch_sql(:service, limit) do
    """
    WITH raw AS (
      SELECT rl.inserted_at::date AS day,
             rl.service_id,
             count(*) AS request_count,
             count(*) FILTER (WHERE rl.status_code >= 400) AS error_count,
             COALESCE(SUM(ROUND(rl.provider_cost_usd * 1000000)), 0)::bigint AS spend_micro
      FROM request_logs rl
      WHERE rl.service_id IS NOT NULL
        AND rl.inserted_at < date_trunc('day', now() AT TIME ZONE 'utc')
      GROUP BY 1, 2
    ), counted AS (
      SELECT c.day, c.service_id, c.request_count, c.error_count, c.spend_micro
      FROM consumption_counters c
      WHERE c.service_id IS NOT NULL
        AND c.day < (now() AT TIME ZONE 'utc')::date
        AND c.day >= (SELECT min(day) FROM raw)
    )
    SELECT COALESCE(raw.day, counted.day),
           COALESCE(raw.service_id, counted.service_id),
           counted.spend_micro,
           raw.spend_micro,
           counted.request_count,
           raw.request_count,
           counted.error_count,
           raw.error_count
    FROM raw
    FULL OUTER JOIN counted ON raw.day = counted.day AND raw.service_id = counted.service_id
    WHERE (counted.spend_micro, counted.request_count, counted.error_count)
          IS DISTINCT FROM
          (raw.spend_micro, raw.request_count, raw.error_count)
    ORDER BY 1 ASC
    LIMIT #{Integer.to_string(limit)}
    """
  end

  # Equality is only meaningful while the top-up's whole history is still in the
  # retention window; `bounds` is the oldest surviving request_logs day.
  defp topup_mismatch_sql(limit) do
    """
    WITH bounds AS (
      SELECT min(rl.inserted_at)::date AS oldest_day FROM request_logs rl
    ), raw AS (
      SELECT rl.credit_topup_id AS topup_id,
             count(*) AS request_count,
             COALESCE(SUM(ROUND(rl.provider_cost_usd * 1000000)), 0)::bigint AS consumed_micro
      FROM request_logs rl
      JOIN credit_topups cp ON cp.id = rl.credit_topup_id
      JOIN bounds b ON cp.inserted_at::date >= b.oldest_day
      WHERE rl.credit_topup_id IS NOT NULL
      GROUP BY 1
    ), counted AS (
      SELECT t.topup_id, t.request_count, t.consumed_micro
      FROM topup_consumption_counters t
      JOIN credit_topups cp ON cp.id = t.topup_id
      JOIN bounds b ON cp.inserted_at::date >= b.oldest_day
    )
    SELECT COALESCE(raw.topup_id, counted.topup_id),
           counted.consumed_micro,
           raw.consumed_micro,
           counted.request_count,
           raw.request_count
    FROM raw
    FULL OUTER JOIN counted ON raw.topup_id = counted.topup_id
    WHERE (counted.consumed_micro, counted.request_count)
          IS DISTINCT FROM
          (raw.consumed_micro, raw.request_count)
    ORDER BY 1 ASC
    LIMIT #{Integer.to_string(limit)}
    """
  end

  # The invariant that holds for EVERY top-up, however old: the counter can be
  # higher than the surviving logs (earlier debits were purged) but never lower.
  defp topup_underreported_sql(limit) do
    """
    SELECT rl.credit_topup_id,
           COALESCE(t.consumed_micro, 0),
           COALESCE(SUM(ROUND(rl.provider_cost_usd * 1000000)), 0)::bigint,
           COALESCE(t.request_count, 0),
           count(*)
    FROM request_logs rl
    LEFT JOIN topup_consumption_counters t ON t.topup_id = rl.credit_topup_id
    WHERE rl.credit_topup_id IS NOT NULL
    GROUP BY rl.credit_topup_id, t.consumed_micro, t.request_count
    HAVING COALESCE(t.consumed_micro, 0) < COALESCE(SUM(ROUND(rl.provider_cost_usd * 1000000)), 0)
    ORDER BY 1 ASC
    LIMIT #{Integer.to_string(limit)}
    """
  end
end
