defmodule Tokengate.Repo.Migrations.CreateTeamMemberExtraAliases do
  use Ecto.Migration

  def change do
    create table(:team_member_extra_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_member_id, references(:team_members, type: :binary_id), null: false
      add :model_alias_id, references(:model_aliases, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_member_extra_aliases, [:team_member_id, :model_alias_id])
  end
end
