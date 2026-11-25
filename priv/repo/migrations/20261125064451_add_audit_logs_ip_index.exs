defmodule Tokengate.Repo.Migrations.AddAuditLogsIpIndex do
  use Ecto.Migration

  def up do
    execute "CREATE INDEX IF NOT EXISTS audit_logs_ip_index ON audit_logs (ip)"
  end

  def down do
    execute "DROP INDEX IF EXISTS audit_logs_ip_index"
  end
end
