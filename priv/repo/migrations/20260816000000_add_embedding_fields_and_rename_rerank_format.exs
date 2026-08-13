defmodule Tokengate.Repo.Migrations.AddEmbeddingFieldsAndRenameRerankFormat do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE providers RENAME COLUMN rerank_dialect TO rerank_format",
      "ALTER TABLE providers RENAME COLUMN rerank_format TO rerank_dialect"
    )

    alter table(:providers) do
      add :embedding_base_url, :string, null: true
      add :embedding_format, :string, null: true, default: "openai"
    end
  end
end
