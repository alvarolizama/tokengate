defmodule Tokengate.Repo.Migrations.AddApiKeysServiceIndexAndWidenUserCovering do
  use Ecto.Migration

  # Follows up the 2026111218580x index migrations after a query audit:
  #
  # 1. `api_keys` had no usable index for the service-scoped key listings
  #    (list_api_keys_for_service/1 and _all/1 run on every stats page mount):
  #    `WHERE service_id = ?` fell back to a seq scan.
  #
  # 2. The covering indexes on `request_logs` only included
  #    `provider_cost_usd`, but the per-subject aggregates (Logs.cost_summary,
  #    Logs.user_stats/2, Credits.only_limit_filter's `credit_topup_id IS
  #    NULL`) also sum tokens/latency and filter on `credit_topup_id`,
  #    forcing a heap fetch per row. Widen both INCLUDE lists.
  #
  # 3. Whole-history aggregates (Logs.total_spend_by_service/0, the per-user
  #    mirror, Credits.spend_by_subjects/2 with since(nil)): a partial index on
  #    the subject column alone keeps them index-only (measured 44.9ms seq
  #    scan -> 9.1ms with 800k rows) without bloating the covering indexes.
  #
  # `request_logs` is partitioned, so CONCURRENTLY does not apply: indexes are
  # created on the parent and new partitions inherit them automatically.
  def up do
    execute(
      "CREATE INDEX IF NOT EXISTS api_keys_service_idx ON api_keys (service_id, inserted_at DESC)"
    )

    execute("DROP INDEX IF EXISTS request_logs_user_spend_covering_idx")

    execute("""
    CREATE INDEX request_logs_user_spend_covering_idx
    ON request_logs (user_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, credit_topup_id
    )
    """)

    execute("DROP INDEX IF EXISTS request_logs_service_spend_covering_idx")

    execute("""
    CREATE INDEX request_logs_service_spend_covering_idx
    ON request_logs (service_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, api_key_id,
      credit_topup_id
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS request_logs_service_spend_all_idx
    ON request_logs (service_id) INCLUDE (provider_cost_usd)
    WHERE service_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS request_logs_user_spend_all_idx
    ON request_logs (user_id) INCLUDE (provider_cost_usd)
    WHERE user_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS api_keys_service_idx")
    execute("DROP INDEX IF EXISTS request_logs_user_spend_all_idx")
    execute("DROP INDEX IF EXISTS request_logs_service_spend_all_idx")

    execute("DROP INDEX IF EXISTS request_logs_service_spend_covering_idx")

    execute("""
    CREATE INDEX request_logs_service_spend_covering_idx
    ON request_logs (service_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, api_key_id
    )
    """)

    execute("DROP INDEX IF EXISTS request_logs_user_spend_covering_idx")

    execute("""
    CREATE INDEX request_logs_user_spend_covering_idx
    ON request_logs (user_id, inserted_at) INCLUDE (provider_cost_usd)
    """)
  end
end
