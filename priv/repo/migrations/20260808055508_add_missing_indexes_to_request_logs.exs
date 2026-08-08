defmodule Tokengate.Repo.Migrations.AddMissingIndexesToRequestLogs do
  @moduledoc """
  Adds composite indexes on request_logs for the most common dashboard
  query patterns that filter by (model_alias_id, inserted_at) and
  (provider_id, inserted_at).

  request_logs is a native Postgres RANGE-partitioned table, so indexes
  must be created on the parent table with raw SQL — Postgres propagates
  them to every existing and future partition automatically.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Composite index for model_alias_id + time range — powers:
    #   - DashboardLive.model_usage_stats_for_members/teams/org
    #     (WHERE model_alias_id IN ... AND inserted_at >= ...)
    #   - Rollup.breakdown_by_credential (WHERE model_alias_id = ...)
    #   - Rollup.breakdown_by_model_for_member
    execute """
    CREATE INDEX IF NOT EXISTS request_logs_model_alias_inserted_idx
      ON request_logs (model_alias_id, inserted_at)
    """

    # Composite index for provider_id + time range — powers:
    #   - Rollup.breakdown_by_credential (GROUP BY provider_id)
    #   - Provider ranking queries
    execute """
    CREATE INDEX IF NOT EXISTS request_logs_provider_inserted_idx
      ON request_logs (provider_id, inserted_at)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_model_alias_inserted_idx"
    execute "DROP INDEX IF EXISTS request_logs_provider_inserted_idx"
  end
end
