defmodule Tokengate.Repo.Migrations.AddClientAgentToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # request_logs is a native Postgres RANGE-partitioned table — raw SQL only.
    execute "ALTER TABLE request_logs ADD COLUMN IF NOT EXISTS client_agent VARCHAR(255)"
  end

  def down do
    execute "ALTER TABLE request_logs DROP COLUMN IF EXISTS client_agent"
  end
end
