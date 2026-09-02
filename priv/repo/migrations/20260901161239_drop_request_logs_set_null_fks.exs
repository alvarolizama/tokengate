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
  - `down/0` re-adds both FKs as `NOT VALID`: once this migration ran,
    deletes leave dangling ids behind, so a full revalidation would fail
    with 23503. NOT VALID skips validating existing rows (new rows are
    still checked) — good enough for a rollback path.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

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
    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';
      ALTER TABLE request_logs ADD CONSTRAINT request_logs_provider_id_fkey
        FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE SET NULL NOT VALID;
      ALTER TABLE request_logs ADD CONSTRAINT request_logs_model_alias_id_fkey
        FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE SET NULL NOT VALID;
    END
    $$;
    """
  end
end
