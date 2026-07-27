defmodule Tokengate.Repo.Migrations.RemoveSubscriptions do
  use Ecto.Migration

  def up do
    alter table(:model_providers) do
      remove :subscription_id
    end

    # request_logs is a partitioned table — need raw SQL to alter
    execute "ALTER TABLE request_logs DROP COLUMN IF EXISTS subscription_id"

    drop_if_exists table(:provider_subscriptions)
  end

  def down do
    create table(:provider_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_id, references(:providers, type: :binary_id), null: false
      add :name, :string, null: false
      add :cost, :decimal, precision: 12, scale: 2, null: false
      add :billing_cycle, :string, null: false
      add :start_date, :date, null: false
      add :end_date, :date
      add :billing_day, :integer
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime)
    end

    create index(:provider_subscriptions, [:provider_id])

    alter table(:model_providers) do
      add :subscription_id, references(:provider_subscriptions, type: :binary_id)
    end

    execute "ALTER TABLE request_logs ADD COLUMN IF NOT EXISTS subscription_id uuid"
  end
end
