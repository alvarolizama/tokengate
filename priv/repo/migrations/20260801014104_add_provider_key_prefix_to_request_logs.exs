defmodule Tokengate.Repo.Migrations.AddProviderKeyPrefixToRequestLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TABLE request_logs ADD COLUMN IF NOT EXISTS provider_key_prefix VARCHAR(255)"
  end

  def down do
    execute "ALTER TABLE request_logs DROP COLUMN IF EXISTS provider_key_prefix"
  end
end
