defmodule Tokengate.Repo.Migrations.ReorderRollupUserIndex do
  @moduledoc """
  Reorders the rollup's per-user index from `(day, hour_utc, user_id)` to
  `(user_id, day, hour_utc)`.

  Same three key columns and the same `INCLUDE` payload — nothing new is
  added, and the index actually gets SMALLER (108 MB vs 147 MB on a 864k-row
  sample). Only the key order changes.

  ## Why

  Every read of `request_metrics_hourly` bounds the window with a RANGE on
  both `day` and `hour_utc` (`Rollup.maybe_rollup_from/2` — the `day` bound
  exists only to give the index a usable prefix). In a btree, once the first
  key is a range the remaining keys cannot narrow the scan, so `user_id` —
  the only column that actually discriminates — was reduced to a filter and
  the planner gave up on the index:

      Parallel Seq Scan on request_metrics_hourly  rows=720  loops=3
        Filter: (user_id = ANY(...) AND hour_utc >= ... AND day >= ...)
        Rows Removed by Filter: 287280     -- per worker, to return 720

  With `user_id` first the same query becomes an index-only scan:

  | window  | users | before  | after   |
  |---------|-------|---------|---------|
  | 1 day   | 1     | 0.18 ms | 0.05 ms |
  | 1 day   | 25    | 4.04 ms | 0.40 ms |
  | 7 days  | 1     | 0.71 ms | 0.11 ms |
  | 7 days  | 25    | 14.2 ms | 1.70 ms |
  | 30 days | 1     | 21.2 ms | 0.31 ms |
  | 30 days | 25    | 26.2 ms | 7.03 ms |

  Org-wide scopes (hundreds of user ids) keep their sequential scan; that is
  the correct plan and this change does not affect it.

  ## What it does NOT break

  The lost `day` prefix leaves no gap: `request_metrics_hourly_hour_idx` is
  `(day, hour_utc)` with the same payload and serves every date-hour-only
  read, and the other per-dimension indexes (`member_idx`, `model_idx`,
  `provider_idx`) keep their own prefixes for their own scopes.

  ## Online

  `request_metrics_hourly` is NOT partitioned, so `CONCURRENTLY` is available
  — the rollup worker keeps writing every minute while this runs. The
  migration lock is disabled because these statements cannot share a
  transaction with `CONCURRENTLY`.

  A failed `CREATE INDEX CONCURRENTLY` leaves an INVALID index behind, so the
  build drops any leftover first and the swap is only reachable once the new
  index is valid.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index :request_metrics_hourly_user_idx
  @staging :request_metrics_hourly_user_idx_ordered

  # Identical payload to the index being replaced: an index-only scan needs
  # every summed column to live in the index.
  @include """
  INCLUDE (request_count, error_count, prompt_tokens, completion_tokens,
           cache_read_tokens, cache_creation_tokens, cost_micro,
           total_latency_ms, latency_count)
  """

  def up do
    # Leftover from an interrupted run: an INVALID index would make the swap
    # below a no-op that silently keeps the old key order.
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@staging}"

    execute """
    CREATE INDEX CONCURRENTLY #{@staging}
      ON request_metrics_hourly (user_id, day, hour_utc)
      #{@include}
    """

    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@index}"
    execute "ALTER INDEX #{@staging} RENAME TO #{@index}"
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@staging}"

    execute """
    CREATE INDEX CONCURRENTLY #{@staging}
      ON request_metrics_hourly (day, hour_utc, user_id)
      #{@include}
    """

    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@index}"
    execute "ALTER INDEX #{@staging} RENAME TO #{@index}"
  end
end
