defmodule Tokengate.Repo.Migrations.AddExtraMonthlyBudgetToTeamMembers do
  use Ecto.Migration

  def change do
    alter table(:team_members) do
      add :extra_monthly_budget_usd, :decimal, precision: 12, scale: 2
    end
  end
end
