defmodule Tokengate.Repo.Migrations.MigrateBudgetToMonthly do
  use Ecto.Migration

  def up do
    # teams: rename default_daily_budget_usd → monthly_budget_per_user_usd
    execute "ALTER TABLE teams RENAME COLUMN default_daily_budget_usd TO monthly_budget_per_user_usd"

    # teams: drop team_daily_budget_usd
    execute "ALTER TABLE teams DROP COLUMN team_daily_budget_usd"

    # team_members: rename extra_daily_budget_usd → extra_monthly_budget_usd
    execute "ALTER TABLE team_members RENAME COLUMN extra_daily_budget_usd TO extra_monthly_budget_usd"

    # team_member_extra_aliases: drop extra_daily_budget_usd
    execute "ALTER TABLE team_member_extra_aliases DROP COLUMN extra_daily_budget_usd"
  end

  def down do
    # teams: re-add team_daily_budget_usd
    alter table(:teams) do
      add :team_daily_budget_usd, :decimal
    end

    # teams: rename monthly_budget_per_user_usd → default_daily_budget_usd
    execute "ALTER TABLE teams RENAME COLUMN monthly_budget_per_user_usd TO default_daily_budget_usd"

    # team_members: rename extra_monthly_budget_usd → extra_daily_budget_usd
    execute "ALTER TABLE team_members RENAME COLUMN extra_monthly_budget_usd TO extra_daily_budget_usd"

    # team_member_extra_aliases: re-add extra_daily_budget_usd
    alter table(:team_member_extra_aliases) do
      add :extra_daily_budget_usd, :decimal
    end
  end
end
