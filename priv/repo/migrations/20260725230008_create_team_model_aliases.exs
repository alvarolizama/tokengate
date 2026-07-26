defmodule Tokengate.Repo.Migrations.CreateTeamModelAliases do
  use Ecto.Migration

  def change do
    create table(:team_model_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id), null: false
      add :model_alias_id, references(:model_aliases, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_model_aliases, [:team_id, :model_alias_id])
  end
end
