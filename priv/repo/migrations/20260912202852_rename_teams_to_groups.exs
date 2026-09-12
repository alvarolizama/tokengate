defmodule Tokengate.Repo.Migrations.RenameTeamsToGroups do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # --- tables ---
    rename table(:teams), to: table(:groups)
    rename table(:team_members), to: table(:group_members)
    rename table(:team_models), to: table(:group_models)
    rename table(:team_member_extra_models), to: table(:group_member_extra_models)

    # --- columns (partition parents: the rename cascades to every child) ---
    rename table(:group_members), :team_id, to: :group_id
    rename table(:group_members), :team_role, to: :group_role
    rename table(:group_models), :team_id, to: :group_id
    rename table(:group_member_extra_models), :team_member_id, to: :group_member_id
    rename table(:api_keys), :team_member_id, to: :group_member_id
    rename table(:budget_exemptions), :team_id, to: :group_id
    rename table(:model_providers), :exclusive_to_team_id, to: :exclusive_to_group_id

    rename table(:model_providers), :exclusive_to_team_member_id,
      to: :exclusive_to_group_member_id

    rename table(:observability_destinations), :team_id, to: :group_id
    rename table(:request_metrics_hourly), :team_member_id, to: :group_member_id
    # request_logs is RANGE-partitioned: renaming the parent column cascades
    # to all partitions (their columns are inherited and cannot be renamed
    # individually on modern Postgres).
    rename table(:request_logs), :team_member_id, to: :group_member_id

    # --- semantic values stored as strings ---
    execute "UPDATE budget_exemptions SET subject_type = 'group' WHERE subject_type = 'team'"

    # The two subject_type='team' partial unique indexes embed the old value
    # in their PREDICATE — rename alone keeps the stale predicate and the
    # index stops matching group rows. Recreate with the new value.
    execute "DROP INDEX IF EXISTS budget_exemptions_global_daily_team_unique"
    execute "DROP INDEX IF EXISTS budget_exemptions_user_daily_team_unique"

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS budget_exemptions_global_daily_group_unique
      ON budget_exemptions USING btree (group_id)
      WHERE scope = 'global_daily' AND subject_type = 'group' AND group_id IS NOT NULL
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS budget_exemptions_user_daily_group_unique
      ON budget_exemptions USING btree (user_id)
      WHERE scope = 'user_daily' AND subject_type = 'group' AND group_id IS NOT NULL
    """

    rename_all_the_things("team", "group")
  end

  def down do
    # Recreate the 'team'-predicated partial indexes, then let the generic
    # renamer handle everything else.
    execute "DROP INDEX IF EXISTS budget_exemptions_global_daily_group_unique"
    execute "DROP INDEX IF EXISTS budget_exemptions_user_daily_group_unique"

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS budget_exemptions_global_daily_team_unique
      ON budget_exemptions USING btree (team_id)
      WHERE scope = 'global_daily' AND subject_type = 'team' AND team_id IS NOT NULL
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS budget_exemptions_user_daily_team_unique
      ON budget_exemptions USING btree (user_id)
      WHERE scope = 'user_daily' AND subject_type = 'team' AND team_id IS NOT NULL
    """

    rename_all_the_things("group", "team")

    execute "UPDATE budget_exemptions SET subject_type = 'team' WHERE subject_type = 'group'"

    rename table(:request_logs), :group_member_id, to: :team_member_id
    rename table(:request_metrics_hourly), :group_member_id, to: :team_member_id
    rename table(:observability_destinations), :group_id, to: :team_id

    rename table(:model_providers), :exclusive_to_group_member_id,
      to: :exclusive_to_team_member_id

    rename table(:model_providers), :exclusive_to_group_id, to: :exclusive_to_team_id
    rename table(:budget_exemptions), :group_id, to: :team_id
    rename table(:api_keys), :group_member_id, to: :team_member_id
    rename table(:group_member_extra_models), :group_member_id, to: :team_member_id
    rename table(:group_models), :group_id, to: :team_id
    rename table(:group_members), :group_role, to: :team_role
    rename table(:group_members), :group_id, to: :team_id

    rename table(:group_member_extra_models), to: table(:team_member_extra_models)
    rename table(:group_models), to: table(:team_models)
    rename table(:group_members), to: table(:team_members)
    rename table(:groups), to: table(:teams)
  end

  # Generic constraint + index rename across the whole schema. We never
  # enumerate exact names: the constraint name a given database carries
  # depends on its migration history (e.g. bridge migrations left
  # `team_member_extra_aliases_*` names on a table now called
  # `group_member_extra_models`), so we match by fragment and apply the
  # full table/column mapping chain. Renaming a PRIMARY KEY constraint
  # renames its backing index too, so the index loop skips pkeys.
  defp rename_all_the_things(old, new) do
    # Identifier mapping chain, longest/most-historical fragments first.
    # Inlined as nested replace() calls (a pg_temp helper would be
    # session-bound and each execute may use a different pool connection).
    map = fn ident ->
      [
        {"#{old}_member_extra_aliases", "#{new}_member_extra_models"},
        {"#{old}_member_extra_models", "#{new}_member_extra_models"},
        {"#{old}_model_aliases", "#{new}_models"},
        {"#{old}_models", "#{new}_models"},
        {"#{old}_members", "#{new}_members"},
        {"#{old}s_#{old}", "#{new}s_#{new}"},
        {"#{old}s", "#{new}s"},
        {"#{old}_member_id", "#{new}_member_id"},
        {"#{old}_model", "#{new}_model"},
        {old, new}
      ]
      |> Enum.reduce(ident, fn {o, n}, acc -> "replace(#{acc}, '#{o}', '#{n}')" end)
    end

    execute """
    DO $$
    DECLARE r record; newname text;
    BEGIN
      FOR r IN
        SELECT conrelid::regclass::text AS tbl, conname
        FROM pg_constraint
        WHERE conname LIKE '%#{old}%'
      LOOP
        newname := #{map.("r.conname")};
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = r.tbl::regclass AND conname = newname
        ) THEN
          EXECUTE format('ALTER TABLE %s RENAME CONSTRAINT %I TO %I',
                         r.tbl, r.conname, newname);
        END IF;
      END LOOP;
    END $$;
    """

    execute """
    DO $$
    DECLARE r record; newname text;
    BEGIN
      FOR r IN
        SELECT schemaname, indexname
        FROM pg_indexes
        WHERE indexname LIKE '%#{old}%'
          AND indexname NOT LIKE '%_pkey%'
      LOOP
        newname := #{map.("r.indexname")};
        IF newname <> r.indexname AND NOT EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE schemaname = r.schemaname AND indexname = newname
        ) THEN
          EXECUTE format('ALTER INDEX %I.%I RENAME TO %I',
                         r.schemaname, r.indexname, newname);
        END IF;
      END LOOP;
    END $$;
    """
  end
end
