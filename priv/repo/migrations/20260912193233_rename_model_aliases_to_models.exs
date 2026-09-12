defmodule Tokengate.Repo.Migrations.RenameModelAliasesToModels do
  @moduledoc """
  The dashboard says "models"; the code now does too. Rename the
  alias-named tables and FK columns to their model equivalents:

    * model_aliases                  → models
    * team_model_aliases             → team_models
    * service_model_aliases          → service_models
    * team_member_extra_aliases      → team_member_extra_models
    * *.model_alias_id               → *.model_id

  Pure metadata renames (rename_table / rename), no data movement.
  Postgres keeps renamed indexes working automatically; we rename the
  ones carrying the old names explicitly (exact names — Postgres never
  auto-renames indexes) so `\d` output stays coherent.
  """
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # {table, old_index_name, new_index_name}
  @index_renames [
    {"models", "model_aliases_pkey", "models_pkey"},
    {"models", "model_aliases_name_index", "models_name_index"},
    {"team_models", "team_model_aliases_pkey", "team_models_pkey"},
    {"team_models", "team_model_aliases_team_id_model_alias_id_index",
     "team_models_team_id_model_id_index"},
    {"service_models", "service_model_aliases_pkey", "service_models_pkey"},
    {"service_models", "service_model_aliases_service_id_model_alias_id_index",
     "service_models_service_id_model_id_index"},
    {"team_member_extra_models", "team_member_extra_aliases_pkey",
     "team_member_extra_models_pkey"},
    {"team_member_extra_models", "team_member_extra_aliases_team_member_id_model_alias_id_index",
     "team_member_extra_models_team_member_id_model_id_index"},
    {"model_providers", "model_providers_model_alias_id_index", "model_providers_model_id_index"},
    {"request_logs", "request_logs_model_alias_inserted_desc_idx",
     "request_logs_model_inserted_desc_idx"},
    {"request_logs_default", "request_logs_default_model_alias_id_inserted_at_idx1",
     "request_logs_default_model_id_inserted_at_idx"}
  ]

  def up do
    rename table(:model_aliases), to: table(:models)
    rename table(:team_model_aliases), to: table(:team_models)
    rename table(:service_model_aliases), to: table(:service_models)
    rename table(:team_member_extra_aliases), to: table(:team_member_extra_models)

    # FK columns pointing at models
    for tbl <- [
          :team_models,
          :service_models,
          :team_member_extra_models,
          :model_providers,
          :request_logs,
          :request_metrics_hourly
        ] do
      rename table(tbl), :model_alias_id, to: :model_id
    end

    for {table, old, new} <- @index_renames do
      rename_index(table, old, new)
    end

    # Pre-existing request_logs partitions keep child indexes with the old
    # column name (created before this migration). Rename any remaining
    # %model_alias% index on request_logs* partitions.
    execute(
      """
      DO $$
      DECLARE i text;
      BEGIN
        FOR i IN
          SELECT indexname FROM pg_indexes
          WHERE tablename LIKE 'request_logs%' AND indexname LIKE '%model_alias%'
        LOOP
          EXECUTE 'ALTER INDEX ' || i || ' RENAME TO ' || replace(i, 'model_alias', 'model');
        END LOOP;
      END $$;
      """,
      ""
    )
  end

  def down do
    rename table(:models), to: table(:model_aliases)
    rename table(:team_models), to: table(:team_model_aliases)
    rename table(:service_models), to: table(:service_model_aliases)
    rename table(:team_member_extra_models), to: table(:team_member_extra_aliases)

    for tbl <- [
          :team_model_aliases,
          :service_model_aliases,
          :team_member_extra_aliases,
          :model_providers,
          :request_logs,
          :request_metrics_hourly
        ] do
      rename table(tbl), :model_id, to: :model_alias_id
    end
  end

  defp rename_index(table, old, new) do
    execute(
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE tablename = '#{table}' AND indexname = '#{old}'
        ) THEN
          EXECUTE 'ALTER INDEX #{old} RENAME TO #{new}';
        END IF;
      END $$;
      """,
      ""
    )
  end
end
