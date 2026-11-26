defmodule Tokengate.Repo.Migrations.AddSmartRouterVersionsAndShadow do
  @moduledoc """
  SmartRouter configuration **versions** and **shadow evaluations**.

  ## From one singleton to one serving Default plus N candidate versions

  `20261126040500_create_smart_router_tables` pinned `router_configs.id` to one
  sentinel by `router_configs_singleton_check`, which made a second candidate
  configuration physically impossible. The invariant the product actually needs
  is narrower: **one serving Default**, any number of non-serving versions.

  So the CHECK is replaced by a partial unique index —

      CREATE UNIQUE INDEX router_configs_single_default_idx
          ON router_configs (is_default) WHERE is_default = true

  — which enforces "at most one `is_default = true`" without forbidding extra
  rows (a plain `UNIQUE (is_default)` would cap the non-default rows at one).
  `Config.get/0` and `Config.ensure!/0` keep returning the Default, so every
  reader written against the singleton keeps working untouched.

  ## Scoping the children

  `router_use_cases` and `router_rules` used to be global: their unique keys
  were `key` and `name` across the whole table. A clone must be able to hold
  the same twelve preset keys and the same rule names as the Default, so both
  gain `router_config_id` (NOT NULL after the backfill) and their unique index
  becomes `(router_config_id, key)` / `(router_config_id, name)`.

  The backfill is deliberately total: rows created before this migration are
  attached to the sentinel id `a750d0c0-0000-4000-8000-000000000001`, and if the
  singleton row itself is missing while orphan children exist the migration
  materialises it as the Default, so no use case is ever left unattached. The
  sentinel insert is guarded by `ON CONFLICT DO NOTHING`: a database that never
  seeded the router gets no row at all, because there is nothing to backfill
  either.

  ## Shadow evaluations

  `router_shadow_evaluations` is a **separate, non-FK child table** of
  `request_logs`, keyed by `(request_log_id, request_inserted_at)` — the pair
  the partitioned log table actually knows (the parent is partitioned by
  `inserted_at`, so the timestamp is what prunes the lookup).

  Why not `request_logs.request_type = "router_shadow"`: that repeats the
  accounting hazard the router telemetry already had to avoid — shadow rows
  would leak into `Budgets`, `/stats` and the hourly rollups, and would bloat
  every one of the ~14 indexes each daily partition carries. A dedicated table
  is written only by the Shadow evaluator, read only by the comparison screens
  and pruned by `PartitionWorker.prune_shadow_evaluations/1`.

  `request_logs` gains **no FK** (`router_config_id` is a plain `uuid`): FKs on
  the partitioned log table made deletes `O(referenced rows)` and were removed
  for exactly that reason; router metadata must also outlive the version row.

  ## Reversible

  `down/0` deletes rows that belong to non-sentinel versions (children first,
  then the versions themselves) before restoring the global unique indexes and
  the singleton CHECK, so a database that already has clones can still roll
  back instead of failing on a duplicate key.
  """

  use Ecto.Migration

  # Sentinel id of the row `Config.ensure!/0` creates (mirrored in the schema).
  @singleton_id "a750d0c0-0000-4000-8000-000000000001"
  @default_name "Default (v1)"

  def up do
    drop constraint(:router_configs, :router_configs_singleton_check)

    alter table(:router_configs) do
      add :name, :string, null: false, default: @default_name
      add :description, :text
      # Exactly one row may be the serving Default (partial unique index below).
      add :is_default, :boolean, null: false, default: false
      # Shadow is an evaluation-only mode: a version so flagged never serves.
      add :shadow_enabled, :boolean, null: false, default: false
      add :shadow_sample_pct, :integer, null: false, default: 100
      add :archived_at, :utc_datetime
    end

    # The pre-existing row (if any) is the Default by definition: `Config.get/0`
    # returned it for every request served so far.
    execute("""
    UPDATE router_configs
       SET is_default = true,
           name = '#{@default_name}',
           updated_at = (now() AT TIME ZONE 'utc')
     WHERE id = '#{@singleton_id}'::uuid
    """)

    create unique_index(:router_configs, [:is_default],
             where: "is_default = true",
             name: :router_configs_single_default_idx
           )

    create constraint(
             :router_configs,
             :router_configs_shadow_sample_pct_check,
             check: "shadow_sample_pct >= 1 AND shadow_sample_pct <= 100"
           )

    # A version cannot both serve every request and be evaluated as a shadow of
    # itself; the changeset refuses it, the CHECK makes the database agree.
    create constraint(
             :router_configs,
             :router_configs_default_not_shadow_check,
             check: "NOT (is_default AND shadow_enabled)"
           )

    add_router_config_id(:router_use_cases)
    add_router_config_id(:router_rules)

    drop index(:router_use_cases, [:key], name: :router_use_cases_key_unique_index)
    drop index(:router_rules, [:name], name: :router_rules_name_unique_index)

    create unique_index(:router_use_cases, [:router_config_id, :key],
             name: :router_use_cases_config_key_unique_index
           )

    create unique_index(:router_rules, [:router_config_id, :name],
             name: :router_rules_config_name_unique_index
           )

    # No FK: see the moduledoc. Plain uuid, same as every other router id on
    # the partitioned log table.
    alter table(:request_logs) do
      add :router_config_id, :binary_id
    end

    create table(:router_shadow_evaluations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The log the evaluation refers to. Deliberately NOT a foreign key:
      # `request_logs` is partitioned and its rows are dropped with their daily
      # partition, while this table is pruned independently by retention.
      add :request_log_id, :binary_id, null: false
      add :request_inserted_at, :utc_datetime, null: false

      # The version that served the request and the version under evaluation.
      add :default_config_id, :binary_id

      add :shadow_config_id,
          references(:router_configs, type: :binary_id, on_delete: :delete_all),
          null: false

      # Denormalised: the row must stay readable after the version is renamed.
      add :shadow_config_name, :string, null: false

      # What the Default decided.
      add :default_use_case_key, :string
      add :default_effort_tier, :string
      add :default_model_id, :binary_id
      add :default_model_name, :string
      add :default_served_cost_usd, :decimal, precision: 12, scale: 6

      # What the Shadow version would have decided.
      add :use_case_key, :string
      add :effort_tier, :string
      add :model_id, :binary_id
      add :model_name, :string
      add :decision_source, :string
      add :decision_ms, :integer
      add :decision_cost_usd, :decimal, precision: 12, scale: 6
      add :prompt_tokens_saved_est, :integer
      add :estimated_served_cost_usd, :decimal, precision: 12, scale: 6

      # Pre-computed disagreement flags: the comparison screens filter on these
      # instead of re-deriving them from names on every read.
      add :matches_default_model, :boolean, null: false, default: false
      add :matches_default_tier, :boolean, null: false, default: false
      add :error_reason, :string

      add :inserted_at, :utc_datetime, null: false
    end

    # Log lookup (join back from a request row / the row-detail modal).
    create index(:router_shadow_evaluations, [:request_log_id, :request_inserted_at],
             name: :router_shadow_evaluations_request_index
           )

    # Per-version comparison over a window.
    create index(:router_shadow_evaluations, [:shadow_config_id, :inserted_at],
             name: :router_shadow_evaluations_config_inserted_at_index
           )

    # Retention prune (`PartitionWorker.prune_shadow_evaluations/1`).
    create index(:router_shadow_evaluations, [:inserted_at],
             name: :router_shadow_evaluations_inserted_at_index
           )
  end

  def down do
    drop table(:router_shadow_evaluations)

    alter table(:request_logs) do
      remove :router_config_id
    end

    # Clones cannot survive the rollback: their keys are unique per version, so
    # the global `unique (key)` / `unique (name)` indexes below would reject
    # them. Children first — the version row cascades onto both tables anyway.
    execute("""
    DELETE FROM router_rules WHERE router_config_id <> '#{@singleton_id}'::uuid
    """)

    execute("""
    DELETE FROM router_use_cases WHERE router_config_id <> '#{@singleton_id}'::uuid
    """)

    execute("""
    DELETE FROM router_configs WHERE id <> '#{@singleton_id}'::uuid
    """)

    drop index(:router_use_cases, [:router_config_id, :key],
           name: :router_use_cases_config_key_unique_index
         )

    drop index(:router_rules, [:router_config_id, :name],
           name: :router_rules_config_name_unique_index
         )

    create unique_index(:router_use_cases, [:key], name: :router_use_cases_key_unique_index)
    create unique_index(:router_rules, [:name], name: :router_rules_name_unique_index)

    remove_router_config_id(:router_use_cases)
    remove_router_config_id(:router_rules)

    drop constraint(:router_configs, :router_configs_default_not_shadow_check)
    drop constraint(:router_configs, :router_configs_shadow_sample_pct_check)
    drop index(:router_configs, [:is_default], name: :router_configs_single_default_idx)

    alter table(:router_configs) do
      remove :archived_at
      remove :shadow_sample_pct
      remove :shadow_enabled
      remove :is_default
      remove :description
      remove :name
    end

    create constraint(
             :router_configs,
             :router_configs_singleton_check,
             check: "id = '#{@singleton_id}'::uuid"
           )
  end

  # `router_config_id` arrives nullable, is backfilled (materialising the
  # sentinel version when there are orphan rows and no version at all), then
  # gets `NOT NULL` so no future writer can create a child without a version.
  defp add_router_config_id(table) do
    alter table(table) do
      add :router_config_id,
          references(:router_configs, type: :binary_id, on_delete: :delete_all)
    end

    execute("""
    INSERT INTO router_configs (id, name, is_default, inserted_at, updated_at)
    SELECT '#{@singleton_id}'::uuid, '#{@default_name}', true,
           (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc')
     WHERE EXISTS (SELECT 1 FROM #{table} WHERE router_config_id IS NULL)
    ON CONFLICT DO NOTHING
    """)

    execute("""
    UPDATE #{table}
       SET router_config_id = '#{@singleton_id}'::uuid
     WHERE router_config_id IS NULL
    """)

    alter table(table) do
      modify :router_config_id, :binary_id, null: false, from: :binary_id
    end
  end

  defp remove_router_config_id(table) do
    alter table(table) do
      remove :router_config_id
    end
  end
end
