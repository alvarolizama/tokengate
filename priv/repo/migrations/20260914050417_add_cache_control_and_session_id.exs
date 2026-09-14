defmodule Tokengate.Repo.Migrations.AddCacheControlAndSessionId do
  use Ecto.Migration

  def change do
    # Explicit cache_control injection flag on model_providers. Off by
    # default — only upstreams that honor Anthropic-style breakpoints
    # benefit (Anthropic, z.ai OpenAI-compatible, OpenRouter passthrough).
    alter table(:model_providers) do
      add :cache_control_enabled, :boolean, default: false, null: false
    end

    # Conversation-level cache affinity key persisted on request_logs:
    # the session_id the gateway derived (client-provided or hashed from
    # the conversation opening). Nullable — requests without a derivable
    # session keep NULL. Enables per-conversation cache-hit observability
    # (cache_read_tokens / prompt_tokens grouped by session).
    alter table(:request_logs) do
      add :session_id, :string
    end

    # Partial index: only rows that carry a session key. request_logs is
    # append-heavy; a full index would bloat writes for NULL rows.
    create index(:request_logs, [:session_id, :inserted_at],
             where: "session_id IS NOT NULL",
             name: :request_logs_session_id_idx
           )
  end
end
