defmodule Tokengate.Repo.Migrations.DropMarketPricesFromModels do
  use Ecto.Migration

  @moduledoc """
  Elimina los precios de mercado informativos de `models`
  (`market_input_price_per_1m`, `market_output_price_per_1m`,
  `market_cache_price_per_1m`).

  Eran display-only y solo alimentaban el «Estimado Mercado» del Calculador; se
  retiran de todos lados. La facturación nunca los leyó: el costo real sale de lo
  que reporta el upstream o del fallback manual por proveedor
  (`model_providers.*_cost_per_million`).

  `down/0` los re-crea con la misma precisión con la que existían
  (`numeric(12,6)`), vacíos: su contenido es irrecuperable al hacer `up`.
  """

  def up do
    alter table(:models) do
      remove :market_input_price_per_1m
      remove :market_output_price_per_1m
      remove :market_cache_price_per_1m
    end
  end

  def down do
    alter table(:models) do
      add :market_input_price_per_1m, :decimal, precision: 12, scale: 6, null: true
      add :market_output_price_per_1m, :decimal, precision: 12, scale: 6, null: true
      add :market_cache_price_per_1m, :decimal, precision: 12, scale: 6, null: true
    end
  end
end
