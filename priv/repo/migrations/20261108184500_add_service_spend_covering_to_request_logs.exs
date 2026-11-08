defmodule Tokengate.Repo.Migrations.AddServiceSpendCoveringToRequestLogs do
  @moduledoc """
  Adds a covering index for the service-scoped cost aggregations
  (`Logs.total_spend_by_service/0` and friends):

      WHERE service_id IS NOT NULL
      GROUP BY service_id
      SUM(provider_cost_usd)

  The existing `request_logs_service_inserted_idx (service_id, inserted_at)`
  resolves the `service_id` grouping but forces a heap fetch for every
  matched row to read `provider_cost_usd` — measured on the audit scratch
  DB (300k rows): Bitmap Heap Scan with ~1.001 heap blocks per partition,
  ~10k buffers across the table. Adding the summed column as INCLUDE turns
  the aggregate into an index-only scan on vacuumed partitions.

  The INCLUDE column does not change the index key, so this index fully
  replaces the old one (lookups, ordering and range scans on
  `(service_id, inserted_at)` all keep working) — the old index is dropped
  in the same migration to avoid paying its write amplification twice.
  Mirror of `20260827054110_add_member_covering_index_to_request_logs`.

  NOTE: `CREATE INDEX ... CONCURRENTLY` cannot run on partitioned tables
  (Postgres limitation), so this is a plain CREATE INDEX. Plan a
  maintenance window for large `request_logs` tables.
  """

  use Ecto.Migration

  @covering_index :request_logs_service_spend_covering_idx
  @legacy_index :request_logs_service_inserted_idx

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS #{@covering_index}
    ON request_logs (service_id, inserted_at)
    INCLUDE (provider_cost_usd)
    """

    execute "DROP INDEX IF EXISTS #{@legacy_index}"
  end

  def down do
    execute """
    CREATE INDEX IF NOT EXISTS #{@legacy_index}
    ON request_logs (service_id, inserted_at)
    """

    execute "DROP INDEX IF EXISTS #{@covering_index}"
  end
end
