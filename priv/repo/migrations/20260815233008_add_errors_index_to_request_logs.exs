defmodule Tokengate.Repo.Migrations.AddErrorsIndexToRequestLogs do
  @moduledoc """
  Adds a partial index on request_logs (status_code) for status_code >= 400,
  powering error-rate / error-listing queries without scanning the full table.

  request_logs is a native Postgres RANGE-partitioned table, so indexes
  must be created on the parent table with raw SQL — Postgres propagates
  them to every existing and future partition automatically.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "CREATE INDEX IF NOT EXISTS request_logs_errors_idx ON request_logs (status_code) WHERE status_code >= 400"
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_errors_idx"
  end
end
