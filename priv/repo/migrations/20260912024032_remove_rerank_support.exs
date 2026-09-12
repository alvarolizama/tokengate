defmodule Tokengate.Repo.Migrations.RemoveRerankSupport do
  use Ecto.Migration

  def up do
    # Existing rerank aliases are demoted to llm before tightening the CHECK,
    # so no row violates the new constraint.
    execute "UPDATE model_aliases SET model_type = 'llm' WHERE model_type = 'rerank'",
            "UPDATE model_aliases SET model_type = 'llm' WHERE model_type = 'rerank'"

    alter table(:providers) do
      remove :rerank_base_url
    end

    execute """
            ALTER TABLE model_aliases
            DROP CONSTRAINT model_aliases_model_type_check;
            """,
            """
            ALTER TABLE model_aliases
            ADD CONSTRAINT model_aliases_model_type_check
            CHECK (((model_type)::text = ANY ((ARRAY['llm'::character varying, 'embedding'::character varying, 'rerank'::character varying])::text[])));
            """

    execute """
            ALTER TABLE model_aliases
            ADD CONSTRAINT model_aliases_model_type_check
            CHECK (((model_type)::text = ANY ((ARRAY['llm'::character varying, 'embedding'::character varying])::text[])));
            """,
            ""
  end

  def down do
    execute """
            ALTER TABLE model_aliases
            DROP CONSTRAINT model_aliases_model_type_check;
            """,
            ""

    execute """
            ALTER TABLE model_aliases
            ADD CONSTRAINT model_aliases_model_type_check
            CHECK (((model_type)::text = ANY ((ARRAY['llm'::character varying, 'embedding'::character varying, 'rerank'::character varying])::text[])));
            """,
            """
            ALTER TABLE model_aliases
            DROP CONSTRAINT model_aliases_model_type_check;
            """

    alter table(:providers) do
      add :rerank_base_url, :varchar, size: 255
    end
  end
end
