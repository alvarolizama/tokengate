defmodule Tokengate.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :cost_tracking_mode, :string, null: false, default: "value"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])
  end
end
