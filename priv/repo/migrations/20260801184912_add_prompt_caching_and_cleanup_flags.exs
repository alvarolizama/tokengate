defmodule Tokengate.Repo.Migrations.AddPromptCachingAndCleanupFlags do
  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      add :prompt_cache_enabled, :boolean, default: false, null: false
      add :lazy_cleanup_enabled, :boolean, default: false, null: false
    end

    alter table(:request_logs) do
      add :cache_read_tokens, :integer, default: 0, null: false
      add :cache_creation_tokens, :integer, default: 0, null: false
    end
  end
end
