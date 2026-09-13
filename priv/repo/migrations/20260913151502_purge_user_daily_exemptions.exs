defmodule Tokengate.Repo.Migrations.PurgeUserDailyExemptions do
  use Ecto.Migration

  # The `user_daily` exemption scope only ever existed to bypass the per-user
  # daily cap. With cap 2 gone, so is the scope: purge its rows and drop its
  # partial unique indexes. `global_daily` (the kill-switch) remains.
  def up do
    execute("DELETE FROM budget_exemptions WHERE scope = 'user_daily'")

    execute("DROP INDEX IF EXISTS budget_exemptions_user_daily_user_unique")
    execute("DROP INDEX IF EXISTS budget_exemptions_user_daily_group_unique")
    execute("DROP INDEX IF EXISTS budget_exemptions_user_daily_service_unique")
  end

  def down do
    create unique_index(:budget_exemptions, [:user_id],
             where: "scope = 'user_daily' AND subject_type = 'user' AND user_id IS NOT NULL",
             name: :budget_exemptions_user_daily_user_unique
           )

    create unique_index(:budget_exemptions, [:group_id],
             where: "scope = 'user_daily' AND subject_type = 'group' AND group_id IS NOT NULL",
             name: :budget_exemptions_user_daily_group_unique
           )

    create unique_index(:budget_exemptions, [:service_id],
             where:
               "scope = 'user_daily' AND subject_type = 'service' AND service_id IS NOT NULL",
             name: :budget_exemptions_user_daily_service_unique
           )
  end
end
