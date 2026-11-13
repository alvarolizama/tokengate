defmodule Tokengate.Repo.Migrations.AddCacheWriteCostToModelProviders do
  @moduledoc """
  Dos correcciones del fallback manual de precio.

  ## 1. Cache WRITE rate (opcional)

  `cache_cost_per_million` cobra los tokens con cache HIT; los tokens que el
  upstream ESCRIBE en la caché (`usage.prompt_tokens_details.cache_write_tokens`,
  normalizado en `cache_creation_tokens`) se persistían pero no se cobraban.
  Anthropic-style los factura con premium (1.25×–2× del input), así que el
  coste manual quedaba corto en cada turno que llenaba la caché.

  `cache_write_cost_per_million` es nullable y OPCIONAL: NULL mantiene
  exactamente la fórmula anterior de tres términos (ningún row cambia de
  coste). Sólo se cobra cuando está presente Y la llamada reporta
  `cache_creation_tokens > 0`. Los tokens de creación se SUMAN al prompt (no
  se restan): el contrato de `UsageNormalizer` los reporta como contador
  distinto, no como subconjunto de `prompt_tokens`.

  ## 2. Semántica de `per_1k_tokens` (corrección de unidad)

  `Pricing.divisor/1` declara `per_1m_tokens → 1_000_000` y
  `per_1k_tokens → 1_000`, pero `CostCalculator` dividía SIEMPRE por 1M: un
  lane que declaraba per-1K se cobraba 1000× menos de lo que su unidad dice.
  El calculador ahora usa `Pricing.divisor(unit)` también en la ruta de
  tokens.

  **Concern de migración**: los rows existentes con `pricing_unit =
  'per_1k_tokens'` guardaron sus tarifas con la interpretación vieja (per 1M,
  que es lo que la fórmula aplicaba y lo que la etiqueta del form prometía).
  Para no cambiarles el coste 1000×, el `up` escala esas tarifas ×1000: el
  coste resultante es idéntico y la tarifa pasa a estar expresada en la
  unidad declarada. El `down` la revierte.
  """

  use Ecto.Migration

  @scaled_columns ~w(input_cost_per_million output_cost_per_million cache_cost_per_million)

  def up do
    alter table(:model_providers) do
      add(:cache_write_cost_per_million, :decimal, precision: 12, scale: 6, null: true)
    end

    # Equivalence-preserving backfill: ver el moduledoc.
    execute(
      """
      UPDATE model_providers
      SET #{Enum.map_join(@scaled_columns, ", ", &"#{&1} = #{&1} * 1000")}
      WHERE pricing_unit = 'per_1k_tokens'
      """,
      """
      UPDATE model_providers
      SET #{Enum.map_join(@scaled_columns, ", ", &"#{&1} = #{&1} / 1000")}
      WHERE pricing_unit = 'per_1k_tokens'
      """
    )
  end

  def down do
    execute("""
    UPDATE model_providers
    SET #{Enum.map_join(@scaled_columns, ", ", &"#{&1} = #{&1} / 1000")}
    WHERE pricing_unit = 'per_1k_tokens'
    """)

    alter table(:model_providers) do
      remove(:cache_write_cost_per_million)
    end
  end
end
