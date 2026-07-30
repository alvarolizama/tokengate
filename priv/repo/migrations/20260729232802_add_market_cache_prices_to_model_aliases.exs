defmodule Tokengate.Repo.Migrations.AddMarketCachePricesToModelAliases do
  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      add :market_cache_read_price_per_1m, :decimal
      add :market_cache_creation_price_per_1m, :decimal
    end
  end
end
