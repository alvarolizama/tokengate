defmodule Tokengate.Repo.Migrations.DropGlobalCapTables do
  use Ecto.Migration

  # The global daily cap (layer 2 of the budget model) is gone: no counter, no
  # worker, no exemption set, no lever. These two tables existed only for it,
  # so they go too — an orphan table with a lying name invites reuse.
  #
  # `budget_exemptions` is recreated here with its final shape (after the
  # teams→groups rename and the `user_daily` scope purge), not its original
  # create: column `group_id`, only the three `global_daily` partial unique
  # indexes and the plain `scope` index.
  def up do
    drop table(:budget_exemptions)
    drop table(:global_settings)
  end

  def down do
    create table(:global_settings, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1
      add :daily_max_spend_usd, :decimal, null: true

      timestamps(type: :utc_datetime)
    end

    execute(
      "INSERT INTO global_settings (id, daily_max_spend_usd, inserted_at, updated_at) VALUES (1, NULL, NOW(), NOW())"
    )

    create table(:budget_exemptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      add :subject_type, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all)
      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all)
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create index(:budget_exemptions, [:scope])

    # One row per (scope, subject) — the `global_daily` bucket, which is the
    # only scope left after the `user_daily` purge.
    create unique_index(:budget_exemptions, [:user_id],
             where: "scope = 'global_daily' AND subject_type = 'user' AND user_id IS NOT NULL",
             name: :budget_exemptions_global_daily_user_unique
           )

    create unique_index(:budget_exemptions, [:group_id],
             where: "scope = 'global_daily' AND subject_type = 'group' AND group_id IS NOT NULL",
             name: :budget_exemptions_global_daily_group_unique
           )

    create unique_index(:budget_exemptions, [:service_id],
             where:
               "scope = 'global_daily' AND subject_type = 'service' AND service_id IS NOT NULL",
             name: :budget_exemptions_global_daily_service_unique
           )
  end
end
