defmodule Tokengate.Repo.Migrations.AddMarketPricesToModels do
  use Ecto.Migration

  @moduledoc """
  Adds informational-only market reference pricing fields to `models`.

  These columns (`market_input_price_per_1m`, `market_output_price_per_1m`,
  `market_cache_price_per_1m`, `market_price_source`, `market_price_synced_at`)
  are strictly display-only (populated manually or via lightweight lookup
  against `models.dev/api.json`). Billing (`CostCalculator`) and consumption
  rollups NEVER read them — actual costs always come from upstream reports or
  per-lane `model_providers` fallback rates.
  """

  def change do
    alter table(:models) do
      add :market_input_price_per_1m, :decimal, precision: 12, scale: 6, null: true
      add :market_output_price_per_1m, :decimal, precision: 12, scale: 6, null: true
      add :market_cache_price_per_1m, :decimal, precision: 12, scale: 6, null: true
      add :market_price_source, :string, null: true
      add :market_price_synced_at, :utc_datetime, null: true
    end
  end
end
