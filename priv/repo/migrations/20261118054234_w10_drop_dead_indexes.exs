defmodule Tokengate.Repo.Migrations.W10DropDeadIndexes do
  @moduledoc """
  Drops the `request_logs` indexes the covering set made redundant (F41).

  Every one of these is either a strict PREFIX of an index that stays, or a
  duplicate of one: keeping both pays the per-partition write cost twice
  (~93 partitions × every INSERT) for a plan the other index already serves.

    * `request_logs_credential_name_idx` `(credential_name, inserted_at)` —
      superseded by `request_logs_credential_inserted_idx`
      `(credential_id, inserted_at)` for the credential drilldown (which seeks
      by id) and by `request_logs_credential_name_idx`'s only real consumer
      being a name filter that now runs against `credential_id`. Measured
      `idx_scan` stays at 0 after the covering indexes landed.
    * `request_logs_session_id_idx` — `session_id` is only ever read through
      the already-pruned `inserted_at` window of a conversation lookup; the
      partial index on a mostly-NULL column never wins the plan.
    * `request_logs_user_spend_all_idx` / `request_logs_service_spend_all_idx`
      `(subject) INCLUDE (provider_cost_usd) WHERE subject IS NOT NULL` —
      whole-history sums. The subject covering indexes
      (`(subject, inserted_at) INCLUDE (…, provider_cost_usd, …)`) serve the
      same query as a prefix range scan and carry strictly more columns, so
      the narrow copies are dead weight.

  `down/0` recreates each index with its exact pre-w10 definition.
  """

  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS request_logs_credential_name_idx")
    execute("DROP INDEX IF EXISTS request_logs_session_id_idx")
    execute("DROP INDEX IF EXISTS request_logs_user_spend_all_idx")
    execute("DROP INDEX IF EXISTS request_logs_service_spend_all_idx")
  end

  def down do
    execute("""
    CREATE INDEX IF NOT EXISTS request_logs_credential_name_idx
    ON request_logs (credential_name, inserted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS request_logs_session_id_idx
    ON request_logs (session_id, inserted_at)
    WHERE session_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS request_logs_user_spend_all_idx
    ON request_logs (user_id) INCLUDE (provider_cost_usd)
    WHERE user_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS request_logs_service_spend_all_idx
    ON request_logs (service_id) INCLUDE (provider_cost_usd)
    WHERE service_id IS NOT NULL
    """)
  end
end
