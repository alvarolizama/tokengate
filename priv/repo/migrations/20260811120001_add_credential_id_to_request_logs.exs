defmodule Tokengate.Repo.Migrations.AddCredentialIdToRequestLogs do
  @moduledoc """
  Denormalizes `credential_id` onto request_logs so per-credential spend
  (daily credential budget) can be aggregated directly without joining
  through model_providers — which would break if a model_provider is
  later re-assigned to a different credential.

  request_logs is a native Postgres RANGE-partitioned table, so the column
  and index are created with raw SQL on the parent table; Postgres
  propagates them to every existing and future partition automatically.

  No foreign key: partitions + FKs are fragile, and the log row must
  survive credential deletion (audit trail).
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TABLE request_logs ADD COLUMN IF NOT EXISTS credential_id UUID"

    # Composite index for credential daily-spend aggregation:
    #   Budgets.Manager lazy-load (WHERE credential_id = ... AND inserted_at >= today)
    execute """
    CREATE INDEX IF NOT EXISTS request_logs_credential_inserted_idx
      ON request_logs (credential_id, inserted_at)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_credential_inserted_idx"
    execute "ALTER TABLE request_logs DROP COLUMN IF EXISTS credential_id"
  end
end
