defmodule Tokengate.Repo.Migrations.ExtendModelTypeToServiceTypes do
  @moduledoc """
  `models.model_type` pasa de `llm | embedding` a los 8 tipos de la superficie
  del gateway: los seis servicios de media (rerank, stt, tts, image, video,
  music) dejan de colapsarse a `llm` en el alta y se persisten con su tipo
  real.

  Sin backfill: los rows de servicio ya creados quedaron como `llm` y no hay
  señal en la base para distinguirlos (el tipo era solo contexto del modal).
  El operador los re-tipea editando el row — el form ya ofrece los 8 valores.
  Relajar el CHECK no invalida ningún dato existente: `llm` y `embedding`
  siguen siendo valores válidos.
  """
  use Ecto.Migration

  # El rename model_aliases → models no renombró el CHECK: sigue llamándose
  # model_aliases_model_type_check. Se renombra aquí y el nuevo nombre es el
  # canónico (models_...), con el mismo rename en el down.
  @old_constraint "model_aliases_model_type_check"
  @new_constraint "models_model_type_check"

  @all ~w(llm embedding rerank stt tts image video music)

  def up do
    execute(
      """
      ALTER TABLE models
      RENAME CONSTRAINT #{@old_constraint} TO #{@new_constraint};
      """,
      """
      ALTER TABLE models
      RENAME CONSTRAINT #{@new_constraint} TO #{@old_constraint};
      """
    )

    execute(
      """
      ALTER TABLE models
      DROP CONSTRAINT #{@new_constraint};
      """,
      """
      ALTER TABLE models
      ADD CONSTRAINT #{@new_constraint}
      CHECK (((model_type)::text = ANY ((ARRAY['llm'::character varying, 'embedding'::character varying])::text[])));
      """
    )

    execute(
      """
      ALTER TABLE models
      ADD CONSTRAINT #{@new_constraint}
      CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@all)}])::text[])));
      """,
      """
      ALTER TABLE models
      DROP CONSTRAINT #{@new_constraint};
      """
    )
  end

  defp quoted(types) do
    types
    |> Enum.map(&"'#{&1}'::character varying")
    |> Enum.join(", ")
  end
end
