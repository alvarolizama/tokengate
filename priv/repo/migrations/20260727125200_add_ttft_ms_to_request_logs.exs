defmodule Tokengate.Repo.Migrations.AddTtftMsToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      # Time to first token (ms) — only recorded for streaming requests.
      # latency_ms for streaming measures generation time (first chunk → done),
      # so perceived total time = ttft_ms + latency_ms.
      add :ttft_ms, :integer, null: true
    end
  end
end
