defmodule Tokengate.Repo.Migrations.CreateTeamMembers do
  use Ecto.Migration

  def change do
    create table(:team_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id), null: false
      add :team_id, references(:teams, type: :binary_id), null: false
      add :team_role, :string, null: false, default: "user"
      add :extra_daily_budget_usd, :decimal, precision: 12, scale: 2
      add :extra_concurrency, :integer
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_members, [:user_id, :team_id],
             name: :team_members_user_team_unique_index
           )

    create index(:team_members, [:team_id])
  end
end
