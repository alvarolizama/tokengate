defmodule Tokengate.Repo.Migrations.AddTeamDailyBudgetToTeams do
  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :team_daily_budget_usd, :decimal, precision: 12, scale: 6, null: true
    end
  end
end
