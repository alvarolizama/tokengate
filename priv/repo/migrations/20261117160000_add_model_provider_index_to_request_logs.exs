defmodule Tokengate.Repo.Migrations.AddModelProviderIndexToRequestLogs do
  @moduledoc """
  Adds the composite lane index that backs the calculator's per-lane queries
  on `request_logs`, and retires the single-column index it supersedes.

  1. `request_logs_model_provider_inserted_idx` — `(model_provider_id,
     inserted_at DESC)`. The calculator reads one lane at a time over a time
     window: equality on `model_provider_id` plus a range on `inserted_at`,
     newest rows first. A leading `model_provider_id` with a descending
     `inserted_at` serves that access path in a single scan (the DESC order
     matches the newest-first reading, and btree can still scan backwards for
     ASC ranges), so no sort and no per-lane heap walk over unrelated rows.

  2. `request_logs_model_provider_id_index` — single column
     `(model_provider_id)`, created in `20260727132747`. The composite key
     starts with the very same column, so every equality lookup that used the
     single-column index keeps working through the composite one. The old
     index is dropped in the same migration to stop paying its write
     amplification for a prefix the composite already maintains — same
     criterion applied to the spend/inserted indexes in `20261112185806`.

  PARTITION NOTE: `request_logs` is RANGE-partitioned on `inserted_at` and
  Postgres does NOT support `CREATE INDEX CONCURRENTLY` on a partitioned
  table, so this is a plain `CREATE INDEX` on the parent (which builds a
  matching index on every attached partition). Partitions created later by
  `Tokengate.Logs.PartitionWorker` inherit the parent indexes automatically
  (`CREATE TABLE ... PARTITION OF`), so no per-partition work is needed.
  Production needs a maintenance window (or an accepted lock) for the build;
  dev/test are unaffected.
  """

  use Ecto.Migration

  @lane_inserted :request_logs_model_provider_inserted_idx
  @lane_legacy :request_logs_model_provider_id_index

  def up do
    # (1) lane + time-window access path for the calculator.
    execute """
    CREATE INDEX IF NOT EXISTS #{@lane_inserted}
      ON request_logs (model_provider_id, inserted_at DESC)
    """

    # (2) the composite key starts with model_provider_id: prefix served.
    execute "DROP INDEX IF EXISTS #{@lane_legacy}"
  end

  def down do
    execute """
    CREATE INDEX IF NOT EXISTS #{@lane_legacy}
      ON request_logs (model_provider_id)
    """

    execute "DROP INDEX IF EXISTS #{@lane_inserted}"
  end
end
