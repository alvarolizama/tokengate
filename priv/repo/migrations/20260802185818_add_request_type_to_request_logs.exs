defmodule Tokengate.Repo.Migrations.AddRequestTypeToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TABLE request_logs ADD COLUMN IF NOT EXISTS request_type VARCHAR(255) NOT NULL DEFAULT 'chat'"
  end

  def down do
    execute "ALTER TABLE request_logs DROP COLUMN IF EXISTS request_type"
  end
end
