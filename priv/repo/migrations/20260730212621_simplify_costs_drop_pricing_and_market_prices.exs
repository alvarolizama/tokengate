defmodule Tokengate.Repo.Migrations.SimplifyCostsDropPricingAndMarketPrices do
  use Ecto.Migration

  @moduledoc """
  Refactor: collapse the four-dimension cost model (cost_usd / provider_cost_usd /
  estimated_cost_usd / savings_usd) into a single `provider_cost_usd` field.

  Drops:
    * `request_logs.cost_usd`
    * `request_logs.estimated_cost_usd`
    * `request_logs.savings_usd`
    * `model_aliases.market_input_price_per_1m`
    * `model_aliases.market_output_price_per_1m`
    * `model_aliases.market_cache_read_price_per_1m`
    * `model_aliases.market_cache_creation_price_per_1m`
    * `model_pricing` table (entirely — manual per-provider pricing is gone)

  `model_providers.billing_mode` stays — it drives the only remaining decision
  (`included` → $0, `pay_per_token` → use provider-reported cost when available).
  """

  def up do
    # 1. Drop the manual pricing table. Foreign-key cascade from model_providers
    #    handles the model_provider_id FK; we still need to drop the explicit FK
    #    constraint before dropping the table itself.
    drop table(:model_pricing)

    # 2. Drop market-price columns from model_aliases.
    alter table(:model_aliases) do
      remove :market_input_price_per_1m
      remove :market_output_price_per_1m
      remove :market_cache_read_price_per_1m
      remove :market_cache_creation_price_per_1m
    end

    # 3. Drop cost_usd / estimated_cost_usd / savings_usd from request_logs.
    #    Postgres partitioned tables need ALTER ... DROP COLUMN on the parent;
    #    it propagates to all partitions.
    alter table(:request_logs) do
      remove :cost_usd
      remove :estimated_cost_usd
      remove :savings_usd
    end
  end

  def down do
    # Reverse order. Restoring everything is a manual data-migration exercise —
    # the original columns are gone and we don't backfill.
    alter table(:request_logs) do
      add :cost_usd, :decimal
      add :estimated_cost_usd, :decimal
      add :savings_usd, :decimal
    end

    alter table(:model_aliases) do
      add :market_input_price_per_1m, :decimal, null: false, default: 0
      add :market_output_price_per_1m, :decimal, null: false, default: 0
      add :market_cache_read_price_per_1m, :decimal
      add :market_cache_creation_price_per_1m, :decimal
    end

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
