defmodule Tokengate.Repo.Migrations.AddCredentialNameIndexToRequestLogs do
  @moduledoc """
  Adds a composite index on (credential_name, inserted_at) for request_logs
  queries that filter/facet by credential name plus a time range.

  request_logs is a native Postgres RANGE-partitioned table, so indexes
  must be created on the parent table with raw SQL — Postgres propagates
  them to every existing and future partition automatically.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "CREATE INDEX IF NOT EXISTS request_logs_credential_name_idx ON request_logs (credential_name, inserted_at)"
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_credential_name_idx"
  end
end
