defmodule Tokengate.Repo.Migrations.AddTeamToObservabilityDestinations do
  use Ecto.Migration

  def up do
    alter table(:observability_destinations) do
      add :team_id, references(:teams, type: :binary_id), null: false
    end

    create index(:observability_destinations, [:team_id])

    alter table(:observability_destinations) do
      remove :privacy_mode
    end
  end

  def down do
    alter table(:observability_destinations) do
      add :privacy_mode, :string, default: "metadata_only"
    end

    drop_if_exists index(:observability_destinations, [:team_id])

    alter table(:observability_destinations) do
      remove :team_id
    end
  end
end
