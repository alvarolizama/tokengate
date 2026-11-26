defmodule Tokengate.Repo.Migrations.AddLatencyToConsumptionCounters do
  @moduledoc """
  Adds latency and TTFT to the durable counters, so speed metrics survive the
  `request_logs` retention too.

  ## Why

  The counters keep money and volume forever (spend, tokens, request/error
  counts) while `request_logs` is pruned at 90 days. Latency and TTFT were not
  in the counter, so `AVG(latency_ms)` / `AVG(ttft_ms)` / TPS simply stopped
  existing for older days — and any aggregate over a wider window returned a
  number that looked complete.

  ## Shape: sum + count, never an average

  An average is not additive across buckets. Storing `SUM` and `COUNT` lets any
  reader rebuild the exact average over an arbitrary range of days and subjects:

      SUM(total_latency_ms) / NULLIF(SUM(latency_count), 0)

  `latency_count` and `ttft_count` are separate on purpose: failed requests can
  have `latency_ms IS NULL`, and non-streaming (or failed-before-first-token)
  rows have `ttft_ms IS NULL`. Dividing by `request_count` would dilute both.
  `AVG()` in SQL skips NULLs — the counts mirror exactly that.

  What this does NOT provide: percentiles. `p50`/`p95`/`p99` need histograms or
  a tdigest; they are deliberately out of scope here.

  ## Cost

  Four `bigint` columns and **zero new rows** — the grain stays
  `(user_id, day)` / `(service_id, day)`. The trigger already runs a single
  `ON CONFLICT DO UPDATE` on the very same row, so the extra work is four
  integer additions inside a statement that was going to happen anyway. No new
  indexes.

  ## Backfill

  The migration fills the closed days the retention still holds, monotone
  (`GREATEST`) exactly like the original counters migration, so a late row or a
  re-run can only raise a bucket. `mix tokengate.counters backfill` finishes
  whatever this snapshot misses. Today's bucket is left to the trigger.
  """

  use Ecto.Migration

  @trigger_function "request_logs_bump_consumption_counters"

  def up do
    alter table(:consumption_counters) do
      add_if_not_exists :total_latency_ms, :bigint, null: false, default: 0
      add_if_not_exists :latency_count, :bigint, null: false, default: 0
      add_if_not_exists :total_ttft_ms, :bigint, null: false, default: 0
      add_if_not_exists :ttft_count, :bigint, null: false, default: 0
    end

    # `CREATE OR REPLACE` keeps the trigger bound to the same function: only the
    # body changes, so no DROP TRIGGER / re-creation window (and no lock on
    # request_logs beyond the catalog update).
    execute("""
    CREATE OR REPLACE FUNCTION #{@trigger_function}() RETURNS trigger AS $$
    BEGIN
      IF NEW.user_id IS NOT NULL THEN
        INSERT INTO consumption_counters AS c
          (user_id, day, request_count, error_count, spend_micro, limit_spend_micro,
           prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens,
           total_latency_ms, latency_count, total_ttft_ms, ttft_count)
        VALUES (
          NEW.user_id,
          (NEW.inserted_at)::date,
          1,
          CASE WHEN NEW.status_code >= 400 THEN 1 ELSE 0 END,
          COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint,
          CASE WHEN NEW.credit_topup_id IS NULL
               THEN COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint
               ELSE 0 END,
          COALESCE(NEW.prompt_tokens, 0),
          COALESCE(NEW.completion_tokens, 0),
          COALESCE(NEW.cache_read_tokens, 0),
          COALESCE(NEW.cache_creation_tokens, 0),
          -- `COALESCE(..., 0)` for the sum, an explicit 0/1 for the count:
          -- AVG() skips NULLs, so a failed request must not enter the divisor.
          COALESCE(NEW.latency_ms, 0)::bigint,
          CASE WHEN NEW.latency_ms IS NULL THEN 0 ELSE 1 END,
          COALESCE(NEW.ttft_ms, 0)::bigint,
          CASE WHEN NEW.ttft_ms IS NULL THEN 0 ELSE 1 END
        )
        ON CONFLICT (user_id, day) WHERE user_id IS NOT NULL DO UPDATE SET
          request_count         = c.request_count         + EXCLUDED.request_count,
          error_count           = c.error_count           + EXCLUDED.error_count,
          spend_micro           = c.spend_micro           + EXCLUDED.spend_micro,
          limit_spend_micro     = c.limit_spend_micro     + EXCLUDED.limit_spend_micro,
          prompt_tokens         = c.prompt_tokens         + EXCLUDED.prompt_tokens,
          completion_tokens     = c.completion_tokens     + EXCLUDED.completion_tokens,
          cache_read_tokens     = c.cache_read_tokens     + EXCLUDED.cache_read_tokens,
          cache_creation_tokens = c.cache_creation_tokens + EXCLUDED.cache_creation_tokens,
          total_latency_ms      = c.total_latency_ms      + EXCLUDED.total_latency_ms,
          latency_count         = c.latency_count         + EXCLUDED.latency_count,
          total_ttft_ms         = c.total_ttft_ms         + EXCLUDED.total_ttft_ms,
          ttft_count            = c.ttft_count            + EXCLUDED.ttft_count,
          updated_at            = (now() AT TIME ZONE 'utc');
      END IF;

      IF NEW.service_id IS NOT NULL THEN
        INSERT INTO consumption_counters AS c
          (service_id, day, request_count, error_count, spend_micro, limit_spend_micro,
           prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens,
           total_latency_ms, latency_count, total_ttft_ms, ttft_count)
        VALUES (
          NEW.service_id,
          (NEW.inserted_at)::date,
          1,
          CASE WHEN NEW.status_code >= 400 THEN 1 ELSE 0 END,
          COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint,
          CASE WHEN NEW.credit_topup_id IS NULL
               THEN COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint
               ELSE 0 END,
          COALESCE(NEW.prompt_tokens, 0),
          COALESCE(NEW.completion_tokens, 0),
          COALESCE(NEW.cache_read_tokens, 0),
          COALESCE(NEW.cache_creation_tokens, 0),
          COALESCE(NEW.latency_ms, 0)::bigint,
          CASE WHEN NEW.latency_ms IS NULL THEN 0 ELSE 1 END,
          COALESCE(NEW.ttft_ms, 0)::bigint,
          CASE WHEN NEW.ttft_ms IS NULL THEN 0 ELSE 1 END
        )
        ON CONFLICT (service_id, day) WHERE service_id IS NOT NULL DO UPDATE SET
          request_count         = c.request_count         + EXCLUDED.request_count,
          error_count           = c.error_count           + EXCLUDED.error_count,
          spend_micro           = c.spend_micro           + EXCLUDED.spend_micro,
          limit_spend_micro     = c.limit_spend_micro     + EXCLUDED.limit_spend_micro,
          prompt_tokens         = c.prompt_tokens         + EXCLUDED.prompt_tokens,
          completion_tokens     = c.completion_tokens     + EXCLUDED.completion_tokens,
          cache_read_tokens     = c.cache_read_tokens     + EXCLUDED.cache_read_tokens,
          cache_creation_tokens = c.cache_creation_tokens + EXCLUDED.cache_creation_tokens,
          total_latency_ms      = c.total_latency_ms      + EXCLUDED.total_latency_ms,
          latency_count         = c.latency_count         + EXCLUDED.latency_count,
          total_ttft_ms         = c.total_ttft_ms         + EXCLUDED.total_ttft_ms,
          ttft_count            = c.ttft_count            + EXCLUDED.ttft_count,
          updated_at            = (now() AT TIME ZONE 'utc');
      END IF;

      IF NEW.credit_topup_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM credit_topups cp WHERE cp.id = NEW.credit_topup_id) THEN
        INSERT INTO topup_consumption_counters AS t
          (topup_id, consumed_micro, request_count)
        VALUES (
          NEW.credit_topup_id,
          COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint,
          1
        )
        ON CONFLICT (topup_id) DO UPDATE SET
          consumed_micro = t.consumed_micro + EXCLUDED.consumed_micro,
          request_count  = t.request_count  + EXCLUDED.request_count,
          updated_at     = (now() AT TIME ZONE 'utc');
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """)

    # Closed days only: today's bucket is the trigger's.
    execute("""
    UPDATE consumption_counters c
       SET total_latency_ms = GREATEST(c.total_latency_ms, s.total_latency_ms),
           latency_count    = GREATEST(c.latency_count,    s.latency_count),
           total_ttft_ms    = GREATEST(c.total_ttft_ms,    s.total_ttft_ms),
           ttft_count       = GREATEST(c.ttft_count,       s.ttft_count)
      FROM (
        SELECT rl.user_id,
               rl.inserted_at::date AS day,
               COALESCE(SUM(rl.latency_ms), 0)::bigint AS total_latency_ms,
               COUNT(rl.latency_ms)::bigint            AS latency_count,
               COALESCE(SUM(rl.ttft_ms), 0)::bigint    AS total_ttft_ms,
               COUNT(rl.ttft_ms)::bigint               AS ttft_count
          FROM request_logs rl
         WHERE rl.user_id IS NOT NULL
           AND rl.inserted_at < date_trunc('day', now() AT TIME ZONE 'utc')
         GROUP BY 1, 2
      ) s
     WHERE c.user_id = s.user_id
       AND c.day = s.day
    """)

    execute("""
    UPDATE consumption_counters c
       SET total_latency_ms = GREATEST(c.total_latency_ms, s.total_latency_ms),
           latency_count    = GREATEST(c.latency_count,    s.latency_count),
           total_ttft_ms    = GREATEST(c.total_ttft_ms,    s.total_ttft_ms),
           ttft_count       = GREATEST(c.ttft_count,       s.ttft_count)
      FROM (
        SELECT rl.service_id,
               rl.inserted_at::date AS day,
               COALESCE(SUM(rl.latency_ms), 0)::bigint AS total_latency_ms,
               COUNT(rl.latency_ms)::bigint            AS latency_count,
               COALESCE(SUM(rl.ttft_ms), 0)::bigint    AS total_ttft_ms,
               COUNT(rl.ttft_ms)::bigint               AS ttft_count
          FROM request_logs rl
         WHERE rl.service_id IS NOT NULL
           AND rl.inserted_at < date_trunc('day', now() AT TIME ZONE 'utc')
         GROUP BY 1, 2
      ) s
     WHERE c.service_id = s.service_id
       AND c.day = s.day
    """)
  end

  def down do
    # Restore the previous body FIRST: dropping the columns under a function
    # that still references them would leave the trigger broken for every
    # subsequent insert.
    execute("""
    CREATE OR REPLACE FUNCTION #{@trigger_function}() RETURNS trigger AS $$
    BEGIN
      IF NEW.user_id IS NOT NULL THEN
        INSERT INTO consumption_counters AS c
          (user_id, day, request_count, error_count, spend_micro, limit_spend_micro,
           prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens)
        VALUES (
          NEW.user_id, (NEW.inserted_at)::date, 1,
          CASE WHEN NEW.status_code >= 400 THEN 1 ELSE 0 END,
          COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint,
          CASE WHEN NEW.credit_topup_id IS NULL
               THEN COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint
               ELSE 0 END,
          COALESCE(NEW.prompt_tokens, 0), COALESCE(NEW.completion_tokens, 0),
          COALESCE(NEW.cache_read_tokens, 0), COALESCE(NEW.cache_creation_tokens, 0)
        )
        ON CONFLICT (user_id, day) WHERE user_id IS NOT NULL DO UPDATE SET
          request_count         = c.request_count         + EXCLUDED.request_count,
          error_count           = c.error_count           + EXCLUDED.error_count,
          spend_micro           = c.spend_micro           + EXCLUDED.spend_micro,
          limit_spend_micro     = c.limit_spend_micro     + EXCLUDED.limit_spend_micro,
          prompt_tokens         = c.prompt_tokens         + EXCLUDED.prompt_tokens,
          completion_tokens     = c.completion_tokens     + EXCLUDED.completion_tokens,
          cache_read_tokens     = c.cache_read_tokens     + EXCLUDED.cache_read_tokens,
          cache_creation_tokens = c.cache_creation_tokens + EXCLUDED.cache_creation_tokens,
          updated_at            = (now() AT TIME ZONE 'utc');
      END IF;

      IF NEW.service_id IS NOT NULL THEN
        INSERT INTO consumption_counters AS c
          (service_id, day, request_count, error_count, spend_micro, limit_spend_micro,
           prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens)
        VALUES (
          NEW.service_id, (NEW.inserted_at)::date, 1,
          CASE WHEN NEW.status_code >= 400 THEN 1 ELSE 0 END,
          COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint,
          CASE WHEN NEW.credit_topup_id IS NULL
               THEN COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint
               ELSE 0 END,
          COALESCE(NEW.prompt_tokens, 0), COALESCE(NEW.completion_tokens, 0),
          COALESCE(NEW.cache_read_tokens, 0), COALESCE(NEW.cache_creation_tokens, 0)
        )
        ON CONFLICT (service_id, day) WHERE service_id IS NOT NULL DO UPDATE SET
          request_count         = c.request_count         + EXCLUDED.request_count,
          error_count           = c.error_count           + EXCLUDED.error_count,
          spend_micro           = c.spend_micro           + EXCLUDED.spend_micro,
          limit_spend_micro     = c.limit_spend_micro     + EXCLUDED.limit_spend_micro,
          prompt_tokens         = c.prompt_tokens         + EXCLUDED.prompt_tokens,
          completion_tokens     = c.completion_tokens     + EXCLUDED.completion_tokens,
          cache_read_tokens     = c.cache_read_tokens     + EXCLUDED.cache_read_tokens,
          cache_creation_tokens = c.cache_creation_tokens + EXCLUDED.cache_creation_tokens,
          updated_at            = (now() AT TIME ZONE 'utc');
      END IF;

      IF NEW.credit_topup_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM credit_topups cp WHERE cp.id = NEW.credit_topup_id) THEN
        INSERT INTO topup_consumption_counters AS t
          (topup_id, consumed_micro, request_count)
        VALUES (NEW.credit_topup_id,
                COALESCE(ROUND(NEW.provider_cost_usd * 1000000), 0)::bigint, 1)
        ON CONFLICT (topup_id) DO UPDATE SET
          consumed_micro = t.consumed_micro + EXCLUDED.consumed_micro,
          request_count  = t.request_count  + EXCLUDED.request_count,
          updated_at     = (now() AT TIME ZONE 'utc');
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """)

    alter table(:consumption_counters) do
      remove :total_latency_ms
      remove :latency_count
      remove :total_ttft_ms
      remove :ttft_count
    end
  end
end
