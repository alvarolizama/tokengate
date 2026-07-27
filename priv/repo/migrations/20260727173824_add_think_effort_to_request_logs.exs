defmodule Tokengate.Repo.Migrations.AddThinkEffortToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      # Reasoning/thinking mode requested by the client (parsed from the
      # payload: `thinking`, `reasoning`, `reasoning_effort`, etc.).
      add :think, :boolean, null: false, default: false
      # Effort level requested ("low", "medium", "high", …) — free-form
      # string because each provider names it differently.
      add :effort, :string, null: true
    end
  end
end
