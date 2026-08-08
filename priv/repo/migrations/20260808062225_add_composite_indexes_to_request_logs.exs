defmodule Tokengate.Repo.Migrations.AddCompositeIndexesToRequestLogs do
  @moduledoc """
  Adds composite indexes on request_logs for the two hottest dashboard /
  proxy query patterns that filter by a foreign id plus a time range:

    * `(team_member_id, inserted_at DESC)` — per-member logs, spend summary,
      top-users cards, CSV export.
    * `(model_alias_id, inserted_at DESC)` — per-model stats, Rollup
      breakdowns, Monitor page.

  request_logs is a native Postgres RANGE-partitioned table on inserted_at,
  so indexes are created on the parent with raw SQL — Postgres propagates
  them to every existing and future partition automatically.

  NOTE: `CREATE INDEX CONCURRENTLY` is NOT supported on partitioned tables
  (Postgres raises `feature_not_supported`), so these run as regular CREATE
  INDEX. On a fresh/small table this is instant; on a large production
  request_logs table schedule a maintenance window.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Composite index for team_member + time range — powers:
    #   - Logs.list_logs/1 filtered by team_member_id
    #   - Logs.cost_summary/1 (budget spend lookups)
    #   - Logs.top_users_last_minutes/3
    #   - StatsExportController CSV export
    execute """
    CREATE INDEX IF NOT EXISTS request_logs_team_member_inserted_idx
      ON request_logs (team_member_id, inserted_at DESC)
    """

    # Composite index for model_alias + time range — powers:
    #   - DashboardLive.model_usage_stats_*
    #   - Rollup.breakdown_by_credential / breakdown_by_model_for_member
    #   - Monitor page per-model bars
    execute """
    CREATE INDEX IF NOT EXISTS request_logs_model_alias_inserted_desc_idx
      ON request_logs (model_alias_id, inserted_at DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_team_member_inserted_idx"
    execute "DROP INDEX IF EXISTS request_logs_model_alias_inserted_desc_idx"
  end
end
