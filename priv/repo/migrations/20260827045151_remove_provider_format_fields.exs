defmodule Tokengate.Repo.Migrations.RemoveProviderFormatFields do
  use Ecto.Migration

  def change do
    alter table(:providers) do
      remove :embedding_format, :string, default: "openai"
      remove :rerank_format, :string, default: "cohere"
    end
  end
end
