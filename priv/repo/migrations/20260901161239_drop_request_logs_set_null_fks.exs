defmodule Tokengate.Repo.Migrations.DropRequestLogsSetNullFks do
  @moduledoc """
  Drops the `provider_id` and `model_alias_id` foreign keys from
  `request_logs` (declared in 20260726000001, retuned to ON DELETE SET
  NULL in 20260728071514).

  Why: these FKs are unbounded work at delete time. Deleting one provider
  forces Postgres to visit EVERY log row referencing it across every
  partition to SET NULL — in production this exceeds the DB timeout and
  the delete never lands. The codebase already solved the identical
  problem for `credential_id` (20260811120001): no FK, because "the log
  row must survive credential deletion (audit trail)". Same reasoning
  applies to provider/model_alias: log rows keep their ids as plain
  historical data; metrics that group by provider/alias name (not id)
  are unaffected.

  Indexes: none of the request_logs indexes on these columns exist to
  serve FK maintenance, and app queries filter/partition by inserted_at
  first, so no replacement index is needed.

  ## Operational notes

  - Each directive runs as ONE `DO` block so `SET LOCAL lock_timeout`
    applies to the ALTERs in the same session/transaction. A bare `SET`
    would be session-scoped and could land on a different pooled
    connection than the ALTERs (@disable_ddl_transaction). DROP
    CONSTRAINT needs ACCESS EXCLUSIVE on the parent and every partition;
    if it queues behind a long query (Rollup windows, cost backfill) it
    would block ALL request_logs inserts (write_worker) while waiting —
    the 3s lock_timeout fails fast instead, and the migration can simply
    be re-run in a quieter moment (`IF EXISTS`, idempotent).
  - `down/0` re-adds both FKs as **validated** (`ON DELETE SET NULL`), not
    `NOT VALID`: `ADD CONSTRAINT ... NOT VALID` on a partitioned table is
    rejected by Postgres < 18 (`42809 wrong_object_type`) — which is what
    AlloyDB (the production server, PG 15/16 lineage) runs on. A validated
    add cannot tolerate the dangling ids this migration deliberately leaves
    behind, so the rollback nulls them out first (see the `down/0` block);
    after this migration ran, new rows are still checked on the way in.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @fk_specs [
    {"request_logs_provider_id_fkey", "provider_id", "providers"},
    {"request_logs_model_alias_id_fkey", "model_alias_id", "model_aliases"}
  ]

  def up do
    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';
      ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_provider_id_fkey;
      ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_model_alias_id_fkey;
    END
    $$;
    """
  end

  def down do
    Enum.each(@fk_specs, fn {name, column, referenced} ->
      execute add_fk(name, column, referenced)
    end)
  end

  # Validated add (no NOT VALID — unsupported on partitioned tables before
  # PG 18). Nulls out the ids that no longer resolve before re-adding, so the
  # validation pass cannot fail with 23503.
  defp add_fk(name, column, referenced) do
    """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';
      ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS #{name};

      BEGIN
        ALTER TABLE request_logs ADD CONSTRAINT #{name}
          FOREIGN KEY (#{column}) REFERENCES #{referenced}(id) ON DELETE SET NULL;
      EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'request_logs: #{column} with no #{referenced} row, nulling them out to re-add the FK';
        UPDATE request_logs SET #{column} = NULL
         WHERE #{column} IS NOT NULL
           AND NOT EXISTS (
             SELECT 1 FROM #{referenced} r WHERE r.id = request_logs.#{column}
           );

        ALTER TABLE request_logs ADD CONSTRAINT #{name}
          FOREIGN KEY (#{column}) REFERENCES #{referenced}(id) ON DELETE SET NULL;
      END;
    END
    $$;
    """
  end
end
