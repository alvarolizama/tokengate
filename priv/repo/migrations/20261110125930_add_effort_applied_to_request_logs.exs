defmodule Tokengate.Repo.Migrations.AddEffortAppliedToRequestLogs do
  @moduledoc """
  Adds `effort_applied` to `request_logs`: the reasoning effort value the
  WINNING attempt actually sent to the upstream wire (nil = no effort field on
  the wire). `effort` keeps storing the client's INTENT, so a rewrite by the
  operator's effort policy (`models.effort_default` / `effort_override`) is
  visible as the pair (intent, applied).

  Append-only table: the column is populated on INSERT (`WriteWorker`), never
  updated. NULL on all historical rows.
  """

  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :effort_applied, :string
    end
  end
end
