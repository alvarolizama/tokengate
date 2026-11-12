defmodule Tokengate.Repo.Migrations.OptimizeRequestLogsSpendIndexes do
  @moduledoc """
  Reworks the `request_logs` indexes that back the spend/latency aggregations
  and the newest-first timeline.

  1. `request_logs_user_spend_covering_idx` — `(user_id, inserted_at)`
     `INCLUDE (provider_cost_usd)`. Same key as the existing
     `request_logs_user_inserted_idx`, so it fully replaces it: every range
     lookup and ordering on `(user_id, inserted_at)` keeps working and the
     `SUM(provider_cost_usd)` aggregation becomes an index-only scan. The old
     index is dropped in the same migration to avoid paying its write
     amplification twice. (Mirror of the member/service covering indexes.)

  2. `request_logs_service_spend_covering_idx` — rebuilt with a wider
     `INCLUDE` list `(id, provider_cost_usd, prompt_tokens, completion_tokens,
     cache_read_tokens, cache_creation_tokens, latency_ms, api_key_id)` so the
     service-scoped aggregates (tokens, latency, per-key spend) are served
     without heap fetches. Same index name and same key columns, so the old
     definition is dropped and recreated in place.

  3. `request_logs_inserted_id_desc_idx` — `(inserted_at DESC, id DESC)`, the
     keyset/timeline ordering used by `Logs` listings
     (`ORDER BY inserted_at DESC` with an `id` tie-break for stable
     pagination). It replaces the single-column `request_logs_inserted_idx`:
     `inserted_at` is its leading column, so plain range scans on
     `inserted_at` still use it (btree can scan backwards for ASC ranges)
     while the duplicate single-column index stops being maintained.

  PARTITION NOTE: `request_logs` is RANGE-partitioned on `inserted_at` and
  Postgres does NOT support `CREATE INDEX CONCURRENTLY` on a partitioned
  table, so these are plain `CREATE INDEX` statements on the parent (which
  builds a matching index on every attached partition). Partitions created
  later by `Tokengate.Logs.PartitionWorker` inherit the parent indexes
  automatically (`CREATE TABLE ... PARTITION OF`), so no per-partition work
  is needed. Production needs a maintenance window (or an accepted lock) for
  the build; dev/test are unaffected.
  """

  use Ecto.Migration

  @user_covering :request_logs_user_spend_covering_idx
  @user_legacy :request_logs_user_inserted_idx

  @service_covering :request_logs_service_spend_covering_idx

  @inserted_desc :request_logs_inserted_id_desc_idx
  @inserted_legacy :request_logs_inserted_idx

  def up do
    # (1) user spend: widen the existing key index with the summed column.
    execute """
    CREATE INDEX IF NOT EXISTS #{@user_covering}
      ON request_logs (user_id, inserted_at)
      INCLUDE (provider_cost_usd)
    """

    execute "DROP INDEX IF EXISTS #{@user_legacy}"

    # (2) service spend: same name, wider payload.
    execute "DROP INDEX IF EXISTS #{@service_covering}"

    execute """
    CREATE INDEX IF NOT EXISTS #{@service_covering}
      ON request_logs (service_id, inserted_at)
      INCLUDE (
        id,
        provider_cost_usd,
        prompt_tokens,
        completion_tokens,
        cache_read_tokens,
        cache_creation_tokens,
        latency_ms,
        api_key_id
      )
    """

    # (3) newest-first timeline / keyset pagination.
    execute """
    CREATE INDEX IF NOT EXISTS #{@inserted_desc}
      ON request_logs (inserted_at DESC, id DESC)
    """

    execute "DROP INDEX IF EXISTS #{@inserted_legacy}"
  end

  def down do
    execute """
    CREATE INDEX IF NOT EXISTS #{@inserted_legacy}
      ON request_logs (inserted_at)
    """

    execute "DROP INDEX IF EXISTS #{@inserted_desc}"

    execute "DROP INDEX IF EXISTS #{@service_covering}"

    execute """
    CREATE INDEX IF NOT EXISTS #{@service_covering}
      ON request_logs (service_id, inserted_at)
      INCLUDE (provider_cost_usd)
    """

    execute """
    CREATE INDEX IF NOT EXISTS #{@user_legacy}
      ON request_logs (user_id, inserted_at)
    """

    execute "DROP INDEX IF EXISTS #{@user_covering}"
  end
end
