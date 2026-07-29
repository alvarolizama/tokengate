defmodule Tokengate.Repo.Migrations.CreateServices do
  use Ecto.Migration

  def change do
    create table(:services, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :monthly_budget_usd, :decimal, precision: 12, scale: 2
      add :concurrency_limit, :integer, null: false, default: 5
      add :rpm_limit, :integer, null: false, default: 60

      timestamps(type: :utc_datetime)
    end

    create table(:service_api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key_hash, :string, null: false
      add :key_prefix, :string, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:service_api_keys, [:service_id])
    create unique_index(:service_api_keys, [:key_hash])

    create table(:service_model_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :model_alias_id, references(:model_aliases, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:service_model_aliases, [:service_id, :model_alias_id])
  end
end
