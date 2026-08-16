defmodule Tokengate.Repo.Migrations.AddAgentTypeIndexToRequestLogs do
  @moduledoc """
  Adds a partial composite index on (agent_type, inserted_at) for request_logs
  where agent_type IS NOT NULL, powering agent-type filtering/breakdown
  queries without scanning the full table.

  request_logs is a native Postgres RANGE-partitioned table, so indexes
  must be created on the parent table with raw SQL — Postgres propagates
  them to every existing and future partition automatically.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "CREATE INDEX IF NOT EXISTS request_logs_agent_type_idx ON request_logs (agent_type, inserted_at) WHERE agent_type IS NOT NULL"
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_agent_type_idx"
  end
end
