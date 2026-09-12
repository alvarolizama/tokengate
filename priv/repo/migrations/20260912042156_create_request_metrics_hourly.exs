defmodule Tokengate.Repo.Migrations.CreateRequestMetricsHourly do
  @moduledoc """
  Creates the hourly metrics rollup table `request_metrics_hourly`.

  One row per (day, hour_utc, team_member_id, model_alias_id, provider_id)
  combination seen in `request_logs`. `request_logs` stays the append-only
  source of truth; this table is fully derived and rebuildable via
  `Tokengate.Metrics.Rollup.HourlyAggregate.backfill/2`.

  Why it exists: period switching on /dashboard and /dashboard/stats
  re-aggregates 9–27 daily partitions of `request_logs` per interaction.
  A 30d/90d series sums ≤ 90×24×N-dimension rows instead of millions of
  request logs — the table stays small (thousands of rows/day even on a
  busy proxy), so it is NOT partitioned; retention is handled by
  `Metrics.RollupWorker.prune/1` deleting rows past the request_logs
  retention window (90d, same policy).

  Postgres 15+ `UNIQUE NULLS NOT DISTINCT` on the bucket columns makes the
  upsert idempotent even for NULL dimension combos (service / anonymous
  traffic). Requires PG >= 15.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS request_metrics_hourly (
      id uuid NOT NULL DEFAULT gen_random_uuid(),
      day date NOT NULL,
      hour_utc timestamp NOT NULL,
      team_member_id uuid,
      model_alias_id uuid,
      provider_id uuid,
      request_count bigint NOT NULL DEFAULT 0,
      error_count bigint NOT NULL DEFAULT 0,
      prompt_tokens bigint NOT NULL DEFAULT 0,
      completion_tokens bigint NOT NULL DEFAULT 0,
      cache_read_tokens bigint NOT NULL DEFAULT 0,
      cache_creation_tokens bigint NOT NULL DEFAULT 0,
      cost_micro bigint NOT NULL DEFAULT 0,
      total_latency_ms bigint NOT NULL DEFAULT 0,
      latency_count bigint NOT NULL DEFAULT 0,
      inserted_at timestamp NOT NULL DEFAULT now(),
      updated_at timestamp NOT NULL DEFAULT now(),
      CONSTRAINT request_metrics_hourly_pkey PRIMARY KEY (id),
      CONSTRAINT request_metrics_hourly_bucket_key UNIQUE NULLS NOT DISTINCT
        (day, hour_utc, team_member_id, model_alias_id, provider_id)
    )
    """

    # Composite indexes match the dashboard query patterns: time-range
    # scans per dimension. (day, hour_utc) first for pure time-range
    # aggregates (org-wide series, hour-of-day distributions).
    execute """
    CREATE INDEX IF NOT EXISTS request_metrics_hourly_member_idx
      ON request_metrics_hourly (day, hour_utc, team_member_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS request_metrics_hourly_model_idx
      ON request_metrics_hourly (day, hour_utc, model_alias_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS request_metrics_hourly_provider_idx
      ON request_metrics_hourly (day, hour_utc, provider_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS request_metrics_hourly_hour_idx
      ON request_metrics_hourly (day, hour_utc)
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS request_metrics_hourly"
  end
end
