defmodule Tokengate.Repo.Migrations.AddAuditLogsFilterIndexes do
  use Ecto.Migration

  def up do
    execute "CREATE INDEX IF NOT EXISTS audit_logs_target_label_index ON audit_logs (target_label)"
  end

  def down do
    execute "DROP INDEX IF EXISTS audit_logs_target_label_index"
  end
end
