defmodule Tokengate.Repo.Migrations.RestrictModelTypesToServedSurface do
  @moduledoc """
  `models.model_type` se restringe a la superficie que el gateway SIRVE:
  `llm embedding decision stt tts image`. Los tipos `video`, `rerank` y
  `music` salen del vocabulario (decisión del dueño) y con ellos sus filas:

    1. `model_providers` de los modelos retirados (los lanes), y después los
       `models`. Esa es la ÚNICA FK hacia `models` que no cascada
       (`model_providers_model_alias_id_fkey` es NO ACTION desde
       `20260725230005`): `team_models`, `service_models`,
       `team_member_extra_models` y `group_member_denied_models` llevan
       `ON DELETE CASCADE`, y `request_logs` ya no lleva FK a `model_id`
       (retirada en `20260901161239`), así que con los lanes fuera no hay
       nada más que cortar.
    2. `providers.path_overrides` pierde las keys `rerank`, `video` y `music`
       (jsonb `-`): quedaban de la era en que esos servicios eran parte del
       vocabulario de `ProviderPaths`.
    3. `providers.capabilities` pierde los tres valores (`array_remove`).

  El CHECK de `models.model_type` se reemplaza al final — los DELETEs van
  ANTES, para que la validación encuentre sólo filas del vocabulario nuevo.
  Con las filas retiradas el ADD es seguro: se agrega `NOT VALID` y se
  valida aparte (`VALIDATE CONSTRAINT`). Nota honesta: Ecto envuelve la
  migración en una transacción, así que el `ACCESS EXCLUSIVE` del ADD se
  retiene hasta el commit y aquí el patrón NO desbloquea lecturas — queda
  por disciplina, para que el día que esto corra con
  `@disable_ddl_transaction true` ya esté en su sitio.

  El módulo define `up/0` y `down/0` explícitos, NO `change/0`: los DELETEs
  y los UPDATE jsonb son irreversibles para el runner de Ecto (un
  `execute/1` con SQL crudo dentro de `change/0` levanta
  `Ecto.MigrationError: cannot reverse migration command` al hacer
  rollback). El `down` restaura el VOCABULARIO anterior — el CHECK de 9
  tipos, idéntico al que dejaba `20260919021000` — no los datos: los
  borrados son irreversibles.
  """
  use Ecto.Migration

  @constraint "models_model_type_check"
  @served ~w(llm embedding decision stt tts image)
  @retired ~w(llm embedding decision rerank stt tts image video music)
  @retired_params Enum.map_join(@retired -- @served, ",", &"'#{&1}'")

  def up do
    execute("""
    DELETE FROM model_providers
    WHERE model_id IN (
      SELECT id FROM models WHERE model_type IN (#{@retired_params})
    );
    """)

    execute("""
    DELETE FROM models WHERE model_type IN (#{@retired_params});
    """)

    execute("""
    UPDATE providers
    SET path_overrides = path_overrides - 'rerank' - 'video' - 'music'
    WHERE path_overrides ?| ARRAY['rerank', 'video', 'music'];
    """)

    execute("""
    UPDATE providers
    SET capabilities = array_remove(
      array_remove(array_remove(capabilities, 'rerank'), 'video'), 'music'
    )
    WHERE capabilities && ARRAY['rerank', 'video', 'music']::varchar[];
    """)

    execute("ALTER TABLE models DROP CONSTRAINT #{@constraint};")

    # NOT VALID + VALIDATE aparte: el ADD no bloquea lecturas mientras
    # escanea, y la validación corrobora que no quedó ninguna fila fuera
    # del vocabulario nuevo (los DELETEs de arriba la garantizan).
    execute("""
    ALTER TABLE models
    ADD CONSTRAINT #{@constraint}
    CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@served)}])::text[])))
    NOT VALID;
    """)

    execute("ALTER TABLE models VALIDATE CONSTRAINT #{@constraint};")
  end

  def down do
    # Restaura el vocabulario de 9 tipos con la MISMA forma que dejaba
    # `20260919021000` (ADD validado inline, sin NOT VALID): las filas
    # vivas son todas del subvocabulario nuevo, así que el CHECK amplio
    # valida sin problema. Los datos borrados NO vuelven.
    execute("ALTER TABLE models DROP CONSTRAINT #{@constraint};")

    execute("""
    ALTER TABLE models
    ADD CONSTRAINT #{@constraint}
    CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@retired)}])::text[])));
    """)
  end

  defp quoted(types) do
    types
    |> Enum.map(&"'#{&1}'::character varying")
    |> Enum.join(", ")
  end
end
