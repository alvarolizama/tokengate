defmodule Tokengate.Repo.Migrations.CreateProviderSubscriptions do
  use Ecto.Migration

  def change do
    create table(:provider_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_id, references(:providers, type: :binary_id), null: false
      add :name, :string, null: false
      add :cost, :decimal, null: false
      add :billing_cycle, :string, null: false
      add :start_date, :date, null: false
      add :end_date, :date
      add :billing_day, :integer
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:provider_subscriptions, [:provider_id])
  end
end
