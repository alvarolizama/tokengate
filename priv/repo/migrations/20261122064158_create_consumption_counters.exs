defmodule Tokengate.Repo.Migrations.CreateConsumptionCounters do
  @moduledoc """
  Durable consumption counters: per-subject-per-day totals and the per-top-up
  consumed amount.

  Why they exist (two independent reasons, both measured):

    * **Money.** `Credits.Topups.consumed_usd/1` summed the raw logs attributed
      to a top-up. `request_logs` keeps 90 days (`PartitionWorker`), so a
      non-expiring top-up older than that lost its debits with the partitions
      and `remaining_usd/1` grew back — spent credit resurrected. The counter
      is the durable record: a top-up is drained by its counter, not by a table
      that gets pruned.
    * **Reads.** The per-subject totals ("total spend" per user/service,
      month-to-date, month-to-date against the limit) were aggregates over
      every retained partition, re-run per cache window and per surface. A
      counter answers them with one index range over subject × day.

  The counters are DERIVED and kept exact by a trigger on `request_logs`
  (`AFTER INSERT FOR EACH ROW`), not by application code: every insert path
  (the Oban `WriteWorker`, its synchronous fallback, seeds, tests, even a
  hand-written INSERT) bumps them in the same transaction as the log, and a
  retried job that hits `ON CONFLICT DO NOTHING` inserts no row and therefore
  bumps nothing. That is the exactly-once guarantee a post-commit bump cannot
  give.

  `user_id` carries no FK on purpose: it is the durable spending identity,
  mirroring `request_logs.user_id` (which has none either). `service_id` does
  cascade, mirroring `request_logs.service_id`.

  The top-up counter cascades from `credit_topups`: deleting a top-up deletes
  its counter, while the historical attribution stays in the logs.

  Reversible: `down/0` drops the trigger, the function and both tables.
  """

  use Ecto.Migration

  @trigger_function "request_logs_bump_consumption_counters"
  @trigger_name "request_logs_consumption_counters"

  def up do
    execute("""
    CREATE TABLE consumption_counters (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid,
      service_id uuid REFERENCES services(id) ON DELETE CASCADE,
      day date NOT NULL,
      request_count bigint NOT NULL DEFAULT 0,
      error_count bigint NOT NULL DEFAULT 0,
      spend_micro bigint NOT NULL DEFAULT 0,
      limit_spend_micro bigint NOT NULL DEFAULT 0,
      prompt_tokens bigint NOT NULL DEFAULT 0,
      completion_tokens bigint NOT NULL DEFAULT 0,
      cache_read_tokens bigint NOT NULL DEFAULT 0,
      cache_creation_tokens bigint NOT NULL DEFAULT 0,
      inserted_at timestamp(0) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at timestamp(0) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      CONSTRAINT consumption_counters_subject_xor
        CHECK (num_nonnulls(user_id, service_id) = 1)
    )
    """)

    # One row per subject per UTC day: the UPSERT target and the range the
    # readers scan.
    execute("""
    CREATE UNIQUE INDEX consumption_counters_user_day_idx
      ON consumption_counters (user_id, day)
      WHERE user_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX consumption_counters_service_day_idx
      ON consumption_counters (service_id, day)
      WHERE service_id IS NOT NULL
    """)

    execute("""
    CREATE TABLE topup_consumption_counters (
      topup_id uuid PRIMARY KEY REFERENCES credit_topups(id) ON DELETE CASCADE,
      consumed_micro bigint NOT NULL DEFAULT 0,
      request_count bigint NOT NULL DEFAULT 0,
      inserted_at timestamp(0) NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at timestamp(0) NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    )
    """)

    execute("""
    CREATE FUNCTION #{@trigger_function}() RETURNS trigger AS $$
    BEGIN
      -- Per-user bucket (subscription subjects). `request_logs.user_id` is the
      -- durable identity; rows with no user are pure service traffic.
      IF NEW.user_id IS NOT NULL THEN
        INSERT INTO consumption_counters AS c
          (user_id, day, request_count, error_count, spend_micro, limit_spend_micro,
           prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens)
        VALUES (
          NEW.user_id,
          -- `inserted_at` is a timestamp WITHOUT time zone that already holds
          -- UTC, so the day is its own date: converting through `AT TIME ZONE`
          -- would re-apply the session's zone and shift the bucket.
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
          COALESCE(NEW.cache_creation_tokens, 0)
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
          COALESCE(NEW.cache_creation_tokens, 0)
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

      -- `request_logs.credit_topup_id` deliberately has no FK: the historical
      -- attribution must survive the deletion of a top-up. This counter does
      -- have one, so a late log for a deleted top-up would raise a
      -- foreign-key violation and take down the whole log insert. Guard the
      -- branch instead: no top-up, no counter to drain.
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

    # On a partitioned table a ROW trigger is cloned onto every partition,
    # existing and future, so the daily partitions created later inherit it.
    execute("""
    CREATE TRIGGER #{@trigger_name}
      AFTER INSERT ON request_logs
      FOR EACH ROW EXECUTE FUNCTION #{@trigger_function}()
    """)

    # One-time backfill of what the retention still holds, so the counters are
    # correct the moment this migration lands (a top-up older than 90 days whose
    # debits were already purged cannot be recovered — the counter starts from
    # what exists).
    #
    # The backfill covers only CLOSED days (`< today`): today's bucket belongs to
    # the trigger. Ecto runs this migration inside one transaction, so the
    # trigger is NOT visible to other sessions until the COMMIT — a log inserted
    # by a session with an open transaction before the lock, committed after this
    # snapshot, is counted by neither side. That window is closed by running
    # `mix tokengate.counters backfill` right after the deploy (it is monotone,
    # so it can only raise a bucket).
    #
    # Every column is written with `GREATEST(c.x, EXCLUDED.x)` instead of a plain
    # REPLACE: a late row for a closed day (the log carries the request START
    # time; the write queue flushes late and Oban retries) can land after this
    # snapshot, and replacing would erase the trigger's correct bump.
    execute("""
    INSERT INTO consumption_counters AS c
      (user_id, day, request_count, error_count, spend_micro, limit_spend_micro,
       prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens)
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
           COALESCE(SUM(rl.cache_creation_tokens), 0)
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
      updated_at            = (now() AT TIME ZONE 'utc')
    """)

    execute("""
    INSERT INTO consumption_counters AS c
      (service_id, day, request_count, error_count, spend_micro, limit_spend_micro,
       prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens)
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
           COALESCE(SUM(rl.cache_creation_tokens), 0)
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
      updated_at            = (now() AT TIME ZONE 'utc')
    """)

    # The top-up counter is money and it must never go DOWN: `GREATEST` keeps a
    # concurrent trigger bump that the snapshot missed and makes the backfill
    # idempotent (re-running never shrinks a drained top-up).
    execute("""
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
    """)
  end

  # ROLLBACK PARCIAL NO ES SEGURO: el código lee estas tablas en el camino
  # caliente (`Topups.consumed_usd/1` dentro de `Manager.ensure_topup_loaded/1`,
  # vía el `reserve` del proxy) y el fallback a logs sólo cubre "no hay fila",
  # no "no hay tabla": un `ecto.rollback` de esta migración con el código nuevo
  # desplegado revienta el reserve con `undefined_table`. Revertir exige revertir
  # el código en el mismo despliegue.
  def down do
    execute("DROP TRIGGER IF EXISTS #{@trigger_name} ON request_logs")
    execute("DROP FUNCTION IF EXISTS #{@trigger_function}()")
    execute("DROP TABLE IF EXISTS topup_consumption_counters")
    execute("DROP TABLE IF EXISTS consumption_counters")
  end
end
