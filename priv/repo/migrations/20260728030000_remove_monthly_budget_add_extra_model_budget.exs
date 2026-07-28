defmodule Tokengate.Repo.Migrations.RemoveMonthlyBudgetAndAddExtraModelBudget do
  use Ecto.Migration

  def change do
    alter table(:teams) do
      remove :default_monthly_budget_usd
    end

    alter table(:team_members) do
      remove :extra_monthly_budget_usd
    end

    alter table(:team_member_extra_aliases) do
      add :extra_daily_budget_usd, :decimal
    end
  end
end
