defmodule Tokengate.Repo.Migrations.AddRerankFieldsToProviders do
  @moduledoc """
  Adds rerank_base_url and rerank_dialect to providers.

  - `rerank_base_url` — optional override for the rerank endpoint URL. When
    nil, the adapter appends `/rerank` to `base_url` (Cohere format).
    When set, the adapter uses this URL and applies the dialect translation.

  - `rerank_dialect` — the payload/response format used by the provider for
    rerank. Values: "cohere" (default, passthrough) or "dashscope" (native
    nested format).
  """
  use Ecto.Migration

  def change do
    alter table(:providers) do
      add(:rerank_base_url, :string, null: true)
      add(:rerank_dialect, :string, null: true, default: "cohere")
    end
  end
end
