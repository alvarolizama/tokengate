defmodule Tokengate.Repo.Migrations.AddMemberCoveringIndexToRequestLogs do
  @moduledoc """
  Adds a covering index for the member-scoped cost aggregations
  (`Logs.cost_summary_for_members/2` and friends):

      WHERE team_member_id = ANY(...) AND inserted_at >= ... AND inserted_at <= ...
      SUM(provider_cost_usd, prompt_tokens, completion_tokens,
          cache_read_tokens, cache_creation_tokens), COUNT(id)

  The existing `request_logs_team_member_inserted_idx (team_member_id,
  inserted_at)` resolves the WHERE clause but forces a heap fetch for every
  matched row to read the summed columns. Adding them (plus `id`, needed by
  `count(id)`) as INCLUDE columns turns the aggregate into an index-only
  scan on vacuumed partitions.

  The INCLUDE columns do not change the index key, so this index fully
  replaces the old one (lookups, ordering, and FK-cascade scans on
  team_member_id all keep working) — the old index is dropped in the same
  migration to avoid paying its write amplification twice.

  NOTE: `CREATE INDEX ... CONCURRENTLY` cannot run on partitioned tables
  (Postgres limitation), so this is a plain CREATE INDEX. Plan a
  maintenance window for large `request_logs` tables.
  """

  use Ecto.Migration

  @covering_index :request_logs_member_inserted_covering_idx
  @legacy_index :request_logs_team_member_inserted_idx

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS #{@covering_index}
    ON request_logs (team_member_id, inserted_at)
    INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens,
             cache_read_tokens, cache_creation_tokens)
    """

    execute "DROP INDEX IF EXISTS #{@legacy_index}"
  end

  def down do
    execute """
    CREATE INDEX IF NOT EXISTS #{@legacy_index}
    ON request_logs (team_member_id, inserted_at)
    """

    execute "DROP INDEX IF EXISTS #{@covering_index}"
  end
end
