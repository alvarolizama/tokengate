defmodule Tokengate.Repo.Migrations.AddMarketPricingToModelAliases do
  use Ecto.Migration

  @moduledoc """
  Re-introduces informational market pricing on model_aliases: reference
  USD rates per 1M tokens (input / output / cache) for operators.

  IMPORTANT: these columns are DISPLAY-ONLY. The billing chain never reads
  them — `CostCalculator` and `manual_pricing` read the per-provider
  fallback rates (`model_providers.*_cost_per_million`) or whatever the
  upstream reports. Do not wire these into cost calculations.
  """

  def change do
    alter table(:model_aliases) do
      add :market_input_price_per_1m, :decimal, precision: 12, scale: 6, null: true
      add :market_output_price_per_1m, :decimal, precision: 12, scale: 6, null: true
      add :market_cache_price_per_1m, :decimal, precision: 12, scale: 6, null: true
    end
  end
end
