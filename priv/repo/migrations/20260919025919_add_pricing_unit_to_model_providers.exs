defmodule Tokengate.Repo.Migrations.AddPricingUnitToModelProviders do
  @moduledoc """
  El costo de una llamada no siempre se mide en tokens.

  `model_providers` sólo sabía de tokens (`input/output/cache_cost_per_million`).
  Para los servicios de media la unidad facturable real es otra: una imagen, un
  megapíxel, un segundo de vídeo o de audio, un minuto transcrito, mil
  caracteres sintetizados. Sin un campo de unidad el fallback manual no podía
  expresarlas, y esos tipos quedaban en $0 salvo que el upstream reportara el
  costo.

  `pricing_unit` es el VOCABULARIO (cerrado, validado también en el changeset) y
  `unit_cost` el precio POR esa unidad. La unidad por defecto es
  `per_1m_tokens`, que es exactamente el comportamiento anterior: los tres
  campos de tokens siguen siendo los parámetros de ESA unidad, así que ningún
  row existente cambia de significado y no hace falta backfill.
  """
  use Ecto.Migration

  @units ~w(
    per_1m_tokens per_1k_tokens per_request per_image per_megapixel
    per_second per_minute per_1k_characters
  )
  @default "per_1m_tokens"
  @constraint "model_providers_pricing_unit_check"

  def up do
    alter table(:model_providers) do
      add :pricing_unit, :string, null: false, default: @default
      add :unit_cost, :decimal
    end

    execute(
      """
      ALTER TABLE model_providers
      ADD CONSTRAINT #{@constraint}
      CHECK ((pricing_unit)::text = ANY ((ARRAY[#{quoted(@units)}])::text[]));
      """,
      "ALTER TABLE model_providers DROP CONSTRAINT #{@constraint};"
    )
  end

  def down do
    execute("ALTER TABLE model_providers DROP CONSTRAINT #{@constraint};")

    alter table(:model_providers) do
      remove :unit_cost
      remove :pricing_unit
    end
  end

  defp quoted(units) do
    units
    |> Enum.map(&"'#{&1}'")
    |> Enum.join(", ")
  end
end
