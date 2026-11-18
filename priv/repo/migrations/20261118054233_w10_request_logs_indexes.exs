defmodule Tokengate.Repo.Migrations.W10RequestLogsIndexes do
  @moduledoc """
  Access paths for the two reads that scan `request_logs` most often, plus
  the rollup's full covering set. Written + tested in dev; applying it to
  production is an owner-gated step with a maintenance window (every
  DROP/CREATE pair below rebuilds the index on each partition).

  Everything here is a plain `CREATE INDEX` on the PARTITIONED parent: new and
  existing partitions inherit it, which is what keeps the operation possible at
  all — `CONCURRENTLY` is not supported on a partitioned table.

  ## F35 — leading `credit_topup_id`

  `credit_topup_id` only ever appeared in the `INCLUDE` of the spend covering
  indexes, so `Credits.Topups.consumed_usd/1` (`SUM(provider_cost_usd) WHERE
  credit_topup_id = ?`, run from the proxy's reserve path and from the admin
  pages every 5s) had no leading column to seek on and walked all ~93
  partitions. Leading `credit_topup_id` + `inserted_at` gives the planner both
  the seek and the date bound `consumed_usd/1` now applies; INCLUDE
  `provider_cost_usd` makes it index-only.

  ## F36 — covering for the model groupings

  `Logs.top_models_for_service/2`, the model × API-key report and the member
  top-models all `GROUP BY model_requested` (or `model_requested` +
  `api_key_id`) and sum cost/tokens while filtering by subject + date. The
  subject covering indexes carry the sums but not the grouping key, so every
  one of those reads heap-fetched every row. Adding `model_requested` and
  `api_key_prefix` to the three subject coverings turns them index-only.

  ## F37 — the rollup's 9 SUMs

  `Rollup.summary_from_rollup/1` sums exactly nine counters
  (`request_count, error_count, prompt_tokens, completion_tokens,
  cache_read_tokens, cache_creation_tokens, cost_micro, total_latency_ms,
  latency_count`). The rollup indexes were prefixed by `(day, hour_utc)` but
  carried only a couple of measures, so the summary was a bitmap heap scan
  over the whole window. Each index below keeps its existing keys and gains
  the full measure list — same access path, index-only result.

  ## F51 — `errors_idx` led by time

  `request_logs_errors_idx` was `(status_code) WHERE status_code >= 400`: every
  error read is a WINDOW read (`inserted_at >= ? AND < ?`), so a status-code
  index cannot prune anything and the partial index only helped as a smaller
  seq scan. Leading `inserted_at` + `INCLUDE (status_code)` lets the window
  prune partitions and ranges, and answers the counts index-only.
  """

  use Ecto.Migration

  # The nine `SUM(...)` columns of `Rollup.summary_from_rollup/1`.
  @rollup_measures """
  request_count, error_count, prompt_tokens, completion_tokens,
  cache_read_tokens, cache_creation_tokens, cost_micro,
  total_latency_ms, latency_count
  """

  def up do
    # --- F35 -------------------------------------------------------------
    execute("""
    CREATE INDEX IF NOT EXISTS request_logs_topup_inserted_idx
    ON request_logs (credit_topup_id, inserted_at)
    INCLUDE (provider_cost_usd)
    WHERE credit_topup_id IS NOT NULL
    """)

    # --- F36 -------------------------------------------------------------
    execute("DROP INDEX IF EXISTS request_logs_service_spend_covering_idx")

    execute("""
    CREATE INDEX request_logs_service_spend_covering_idx
    ON request_logs (service_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, api_key_id,
      credit_topup_id, ttft_ms, status_code, model_requested, api_key_prefix
    )
    """)

    execute("DROP INDEX IF EXISTS request_logs_user_spend_covering_idx")

    execute("""
    CREATE INDEX request_logs_user_spend_covering_idx
    ON request_logs (user_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, credit_topup_id,
      ttft_ms, status_code, model_requested, api_key_prefix
    )
    """)

    execute("DROP INDEX IF EXISTS request_logs_member_inserted_covering_idx")

    execute("""
    CREATE INDEX request_logs_member_inserted_covering_idx
    ON request_logs (group_member_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, ttft_ms, status_code,
      model_requested, api_key_prefix
    )
    """)

    # --- F37 -------------------------------------------------------------
    execute("DROP INDEX IF EXISTS request_metrics_hourly_hour_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_hour_idx
    ON request_metrics_hourly (day, hour_utc)
    INCLUDE (#{@rollup_measures}, provider_id, model_id)
    """)

    execute("DROP INDEX IF EXISTS request_metrics_hourly_member_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_member_idx
    ON request_metrics_hourly (day, hour_utc, group_member_id)
    INCLUDE (#{@rollup_measures})
    """)

    execute("DROP INDEX IF EXISTS request_metrics_hourly_user_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_user_idx
    ON request_metrics_hourly (day, hour_utc, user_id)
    INCLUDE (#{@rollup_measures})
    """)

    execute("DROP INDEX IF EXISTS request_metrics_hourly_model_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_model_idx
    ON request_metrics_hourly (day, hour_utc, model_id)
    INCLUDE (#{@rollup_measures})
    """)

    execute("DROP INDEX IF EXISTS request_metrics_hourly_provider_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_provider_idx
    ON request_metrics_hourly (day, hour_utc, provider_id)
    INCLUDE (#{@rollup_measures})
    """)

    # --- F51 -------------------------------------------------------------
    execute("DROP INDEX IF EXISTS request_logs_errors_idx")

    execute("""
    CREATE INDEX request_logs_errors_idx
    ON request_logs (inserted_at)
    INCLUDE (status_code)
    WHERE status_code >= 400
    """)
  end

  def down do
    # --- F51 back to (status_code) --------------------------------------
    execute("DROP INDEX IF EXISTS request_logs_errors_idx")

    execute("""
    CREATE INDEX request_logs_errors_idx
    ON request_logs (status_code)
    WHERE status_code >= 400
    """)

    # --- F37 back to the pre-w10 INCLUDE lists ---------------------------
    execute("DROP INDEX IF EXISTS request_metrics_hourly_provider_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_provider_idx
    ON request_metrics_hourly (day, hour_utc, provider_id)
    """)

    execute("DROP INDEX IF EXISTS request_metrics_hourly_model_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_model_idx
    ON request_metrics_hourly (day, hour_utc, model_id)
    """)

    execute("DROP INDEX IF EXISTS request_metrics_hourly_user_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_user_idx
    ON request_metrics_hourly (day, hour_utc, user_id)
    """)

    execute("DROP INDEX IF EXISTS request_metrics_hourly_member_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_member_idx
    ON request_metrics_hourly (day, hour_utc, group_member_id)
    """)

    execute("DROP INDEX IF EXISTS request_metrics_hourly_hour_idx")

    execute("""
    CREATE INDEX request_metrics_hourly_hour_idx
    ON request_metrics_hourly (day, hour_utc)
    INCLUDE (request_count, cost_micro, provider_id, model_id)
    """)

    # --- F36 back to the ttft/status lists -------------------------------
    execute("DROP INDEX IF EXISTS request_logs_member_inserted_covering_idx")

    execute("""
    CREATE INDEX request_logs_member_inserted_covering_idx
    ON request_logs (group_member_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, ttft_ms, status_code
    )
    """)

    execute("DROP INDEX IF EXISTS request_logs_user_spend_covering_idx")

    execute("""
    CREATE INDEX request_logs_user_spend_covering_idx
    ON request_logs (user_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, credit_topup_id,
      ttft_ms, status_code
    )
    """)

    execute("DROP INDEX IF EXISTS request_logs_service_spend_covering_idx")

    execute("""
    CREATE INDEX request_logs_service_spend_covering_idx
    ON request_logs (service_id, inserted_at)
    INCLUDE (
      id, provider_cost_usd, prompt_tokens, completion_tokens,
      cache_read_tokens, cache_creation_tokens, latency_ms, api_key_id,
      credit_topup_id, ttft_ms, status_code
    )
    """)

    # --- F35 -------------------------------------------------------------
    execute("DROP INDEX IF EXISTS request_logs_topup_inserted_idx")
  end
end
