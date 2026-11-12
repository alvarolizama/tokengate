defmodule Tokengate.Repo.Migrations.WidenRequestLogsCoveringTtftStatus do
  @moduledoc """
  Widens the three subject coverings on `request_logs` so the per-subject
  aggregates stay index-only now that they read latency and error columns.

  The aggregates (`Logs.cost_summary/1`, `Logs.service_stats/2`,
  `Logs.user_stats/2`, `Logs.member_stats/2`, `Credits.spend_by_subjects/2`)
  select `AVG(ttft_ms)` and filter `status_code >= 400` (`error_count` /
  `status_breakdown`). Without those two columns in the INCLUDE list, every
  row of the scan needs a heap fetch and the index-only scan is lost.

  1. `request_logs_user_spend_covering_idx` — `(user_id, inserted_at)`
  2. `request_logs_member_inserted_covering_idx` — `(group_member_id, inserted_at)`
  3. `request_logs_service_spend_covering_idx` — `(service_id, inserted_at)`

  Each is DROPped and recreated with the same name and the same key columns,
  only a wider INCLUDE (previous list + `ttft_ms, status_code`). Keeping the
  name preserves every existing lookup/ordering path; keeping the key means
  no second index is maintained on the hot insert path. `down/0` restores the
  exact previous definitions.

  `model_requested` is deliberately NOT included: the audit only justified
  `ttft_ms`/`status_code`, and every extra INCLUDE column is paid on each
  insert into the partitioned table.

  PARTITION NOTE: `request_logs` is RANGE-partitioned on `inserted_at` and
  Postgres does NOT support `CREATE INDEX CONCURRENTLY` on a partitioned
  table, so these run as plain `CREATE INDEX` on the parent (which builds the
  matching index on every attached partition). New daily partitions created
  by `Tokengate.Logs.PartitionWorker` inherit the parent indexes.
  """

  use Ecto.Migration

  @user_covering :request_logs_user_spend_covering_idx
  @member_covering :request_logs_member_inserted_covering_idx
  @service_covering :request_logs_service_spend_covering_idx

  def up do
    execute("DROP INDEX IF EXISTS #{@user_covering}")

    execute("""
    CREATE INDEX #{@user_covering}
    ON request_logs (user_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, credit_topup_id,
      ttft_ms, status_code
    )
    """)

    execute("DROP INDEX IF EXISTS #{@member_covering}")

    execute("""
    CREATE INDEX #{@member_covering}
    ON request_logs (group_member_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, ttft_ms, status_code
    )
    """)

    execute("DROP INDEX IF EXISTS #{@service_covering}")

    execute("""
    CREATE INDEX #{@service_covering}
    ON request_logs (service_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, api_key_id,
      credit_topup_id, ttft_ms, status_code
    )
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@service_covering}")

    execute("""
    CREATE INDEX #{@service_covering}
    ON request_logs (service_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, api_key_id,
      credit_topup_id
    )
    """)

    execute("DROP INDEX IF EXISTS #{@member_covering}")

    execute("""
    CREATE INDEX #{@member_covering}
    ON request_logs (group_member_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens
    )
    """)

    execute("DROP INDEX IF EXISTS #{@user_covering}")

    execute("""
    CREATE INDEX #{@user_covering}
    ON request_logs (user_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, credit_topup_id
    )
    """)
  end
end
