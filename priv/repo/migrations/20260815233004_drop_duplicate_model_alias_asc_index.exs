defmodule Tokengate.Repo.Migrations.DropDuplicateModelAliasAscIndex do
  @moduledoc """
  Drops the ASC composite index (model_alias_id, inserted_at) on request_logs.

  The DESC variant `request_logs_model_alias_inserted_desc_idx` (created in
  AddCompositeIndexesToRequestLogs) covers all queries — Postgres can scan a
  DESC b-tree backwards for ASC order, so the ASC index is redundant.

  request_logs is a native Postgres RANGE-partitioned table, so index DDL
  must run against the parent table with raw SQL.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "DROP INDEX IF EXISTS request_logs_model_alias_inserted_idx"
  end

  def down do
    execute "CREATE INDEX IF NOT EXISTS request_logs_model_alias_inserted_idx ON request_logs (model_alias_id, inserted_at)"
  end
end
