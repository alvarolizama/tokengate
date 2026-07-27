defmodule Tokengate.Repo.Migrations.AddStatusToProviders do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      add :status, :string, null: false, default: "active"
    end
  end
end
