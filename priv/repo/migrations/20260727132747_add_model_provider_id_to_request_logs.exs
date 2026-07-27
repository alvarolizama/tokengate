defmodule Tokengate.Repo.Migrations.AddModelProviderIdToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :model_provider_id, :binary_id
    end

    create index(:request_logs, [:model_provider_id])
  end
end
