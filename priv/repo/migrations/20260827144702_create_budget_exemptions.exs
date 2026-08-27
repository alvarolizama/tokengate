defmodule Tokengate.Repo.Migrations.CreateBudgetExemptions do
  use Ecto.Migration

  def change do
    create table(:budget_exemptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # "global_daily" (exempt from the global daily cap) or "user_daily"
      # (exempt from the per-user daily cap).
      add :scope, :string, null: false
      # "user" | "team" | "service" — which kind of subject is exempt.
      add :subject_type, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all)
      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all)
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create index(:budget_exemptions, [:scope])

    # One row per (scope, subject). Six partial unique indexes — same bucket
    # pattern as model_providers' scope indexes.
    create unique_index(:budget_exemptions, [:user_id],
             where: "scope = 'global_daily' AND subject_type = 'user' AND user_id IS NOT NULL",
             name: :budget_exemptions_global_daily_user_unique
           )

    create unique_index(:budget_exemptions, [:team_id],
             where: "scope = 'global_daily' AND subject_type = 'team' AND team_id IS NOT NULL",
             name: :budget_exemptions_global_daily_team_unique
           )

    create unique_index(:budget_exemptions, [:service_id],
             where:
               "scope = 'global_daily' AND subject_type = 'service' AND service_id IS NOT NULL",
             name: :budget_exemptions_global_daily_service_unique
           )

    create unique_index(:budget_exemptions, [:user_id],
             where: "scope = 'user_daily' AND subject_type = 'user' AND user_id IS NOT NULL",
             name: :budget_exemptions_user_daily_user_unique
           )

    create unique_index(:budget_exemptions, [:team_id],
             where: "scope = 'user_daily' AND subject_type = 'team' AND team_id IS NOT NULL",
             name: :budget_exemptions_user_daily_team_unique
           )

    create unique_index(:budget_exemptions, [:service_id],
             where:
               "scope = 'user_daily' AND subject_type = 'service' AND service_id IS NOT NULL",
             name: :budget_exemptions_user_daily_service_unique
           )
  end
end
