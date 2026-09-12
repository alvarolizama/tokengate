defmodule Tokengate.Repo.Migrations.AddProviderServiceUrls do
  @moduledoc """
  Per-service URL overrides for custom providers.

  Custom providers remain OpenAI-compatible in dialect, but may expose
  each service under a different base path: `chat_url`, `models_url` and
  `embeddings_url` are full-URL overrides (nil = derive from `base_url`).
  Builtins never set them — their single base_url comes from the catalog.
  """

  use Ecto.Migration

  def change do
    alter table(:providers) do
      add :chat_url, :string
      add :models_url, :string
      add :embeddings_url, :string
    end
  end
end
