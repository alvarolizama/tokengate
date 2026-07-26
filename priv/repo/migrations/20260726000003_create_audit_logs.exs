defmodule Tokengate.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id)
      add :action, :string
      add :entity_type, :string
      add :entity_id, :string
      add :changes, :map, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_logs, [:user_id])
    create index(:audit_logs, [:entity_type, :entity_id])
    create index(:audit_logs, [:inserted_at])
  end
end
