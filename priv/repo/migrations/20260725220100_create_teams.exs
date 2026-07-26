defmodule Tokengate.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  def change do
    create table(:teams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :name, :string, null: false
      add :default_daily_budget_usd, :decimal, precision: 12, scale: 2
      add :default_monthly_budget_usd, :decimal, precision: 12, scale: 2
      add :default_concurrency_limit, :integer, null: false, default: 5
      add :default_rpm_limit, :integer, null: false, default: 60

      timestamps(type: :utc_datetime)
    end

    create index(:teams, [:organization_id])
  end
end
