defmodule Tokengate.Repo.Migrations.AddModelTypeToModelAliases do
  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      add :model_type, :string, null: false, default: "llm"
    end

    create constraint(:model_aliases, :model_aliases_model_type_check,
             check: "model_type IN ('llm', 'embedding', 'rerank')"
           )
  end
end
