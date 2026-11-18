defmodule Tokengate.Repo.Migrations.W14RerankModelType do
  @moduledoc """
  `rerank` vuelve al vocabulario de `models.model_type`, esta vez con una
  superficie que lo sirve (`POST /v1/rerank` + `Proxy.Rerank`).

  Historia del CHECK (la tabla fue `model_aliases` hasta `20260912193233`; el
  constraint conservó el nombre viejo y `20260919003854` lo renombró al
  canónico `models_model_type_check`):

    * `20260912024032` retiró `rerank` y demotó sus aliases existentes a
      `llm` — la superficie se había eliminado en `887a1a9`.
    * `20261108214419` restringió el vocabulario a la superficie servida
      (`llm embedding decision stt tts image`) y BORRÓ las filas `rerank`.

  Este `up` sólo AMPLÍA el CHECK: ningún alias existente se toca (no hay filas
  `rerank` que demotar ni que borrar — la migración anterior ya las eliminó, y
  la restauración de datos no es reversible). `rerank` queda declarable desde
  el alta de modelos.

  Reversible: el `down` deja el CHECK exactamente como lo dejó
  `20261108214419`. Si alguna fila `rerank` llegara a existir al revertir, el
  `down` la demota a `llm` ANTES de cerrar el vocabulario (misma política que
  la migración de retirada: la fila sobrevive, sus lanes siguen colgadas), y
  lo documenta.
  """

  use Ecto.Migration

  @constraint "models_model_type_check"
  @served ~w(llm embedding decision stt tts image)
  @with_rerank ~w(llm embedding decision rerank stt tts image)

  def up do
    execute(
      """
      ALTER TABLE models DROP CONSTRAINT #{@constraint};
      """,
      """
      ALTER TABLE models
      ADD CONSTRAINT #{@constraint}
      CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@served)}])::text[])));
      """
    )

    execute(
      """
      ALTER TABLE models
      ADD CONSTRAINT #{@constraint}
      CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@with_rerank)}])::text[])));
      """,
      """
      ALTER TABLE models DROP CONSTRAINT #{@constraint};
      """
    )
  end

  def down do
    # A `rerank` model cannot exist while this migration is the last word on
    # the vocabulary, but a rollback after real traffic could find one: demote
    # it so the narrower CHECK validates without data loss.
    execute("""
    UPDATE models SET model_type = 'llm' WHERE model_type = 'rerank';
    """)

    execute("ALTER TABLE models DROP CONSTRAINT #{@constraint};")

    execute("""
    ALTER TABLE models
    ADD CONSTRAINT #{@constraint}
    CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@served)}])::text[])));
    """)
  end

  defp quoted(types) do
    types
    |> Enum.map(&"'#{&1}'::character varying")
    |> Enum.join(", ")
  end
end
