defmodule Tokengate.Repo.Migrations.RemoveRerankSupport do
  @moduledoc """
  Removes `rerank` support completely from the database:

    1. Deletes any `model_providers` lanes attached to `model_type = 'rerank'`
       models, then deletes those `models` rows.
    2. Strips `"rerank"` from `providers.path_overrides` and
       `providers.capabilities`.
    3. Tightens `models_model_type_check` to the served surface:
       `llm embedding decision stt tts image`.
  """

  use Ecto.Migration

  @constraint "models_model_type_check"
  @served ~w(llm embedding decision stt tts image)

  def up do
    execute("""
    DELETE FROM model_providers
    WHERE model_id IN (
      SELECT id FROM models WHERE model_type = 'rerank'
    );
    """)

    execute("DELETE FROM models WHERE model_type = 'rerank';")

    execute("""
    UPDATE providers
    SET path_overrides = path_overrides - 'rerank'
    WHERE path_overrides ? 'rerank';
    """)

    execute("""
    UPDATE providers
    SET capabilities = array_remove(capabilities, 'rerank')
    WHERE capabilities && ARRAY['rerank']::varchar[];
    """)

    execute("ALTER TABLE models DROP CONSTRAINT #{@constraint};")

    execute("""
    ALTER TABLE models
    ADD CONSTRAINT #{@constraint}
    CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@served)}])::text[])))
    NOT VALID;
    """)

    execute("ALTER TABLE models VALIDATE CONSTRAINT #{@constraint};")
  end

  def down do
    execute("ALTER TABLE models DROP CONSTRAINT #{@constraint};")

    execute("""
    ALTER TABLE models
    ADD CONSTRAINT #{@constraint}
    CHECK (((model_type)::text = ANY ((ARRAY[#{quoted(@served ++ ["rerank"])}])::text[])));
    """)
  end

  defp quoted(types) do
    types
    |> Enum.map(&"'#{&1}'::character varying")
    |> Enum.join(", ")
  end
end
