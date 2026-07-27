defmodule Tokengate.Repo.Migrations.CreateModelPricing do
  use Ecto.Migration

  def change do
    create table(:model_pricing, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :model_provider_id, references(:model_providers, type: :binary_id), null: false
      add :input_price_per_1m, :decimal, null: false
      add :output_price_per_1m, :decimal, null: false
      add :cache_read_price_per_1m, :decimal
      add :cache_creation_price_per_1m, :decimal
      add :effective_from, :utc_datetime, null: false, default: fragment("now()")

      timestamps(type: :utc_datetime)
    end

    create index(:model_pricing, [:model_provider_id])
    create index(:model_pricing, [:model_provider_id, :effective_from])
  end
end
