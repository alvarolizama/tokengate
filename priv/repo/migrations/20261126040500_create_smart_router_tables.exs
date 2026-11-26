defmodule Tokengate.Repo.Migrations.CreateSmartRouterTables do
  @moduledoc """
  SmartRouter persistence: `router_configs`, `router_use_cases`,
  `router_use_case_models` and `router_rules`.

  ## Why a two-level model instead of a flat route table

  A `router_use_case` is a *specialty* ("coding_implement", "data_heavy_finance",
  …) that owns the request-shaping policy of that job — hard capability
  requirements, prompt-saving knobs, session pinning, priority and an optional
  per-use-case fallback. Its `router_use_case_models` are the 2+ catalogue
  models that can serve it, each tagged with the effort tier it covers. A flat
  `router_routes` table would force every row to repeat the specialty's
  description, tags and knobs, and would make "the medium-effort model of
  `coding_implement`" unexpressible.

  Targets point at `models`, never at `model_providers`: a row inherits its
  lanes, credential pools, circuit breakers and pricing from the catalogue it
  is already bound to. Nothing is duplicated here, so adding a model to a use
  case is one row, not a reconfiguration of the provider lane.

  ## Delete semantics

    * `router_use_case_models.target_model_id` — `ON DELETE RESTRICT`. Deleting
      a model that a use case still binds must not silently empty the router;
      `Providers.delete_model/1` declares `router_use_case_models_target_model_id_fkey`
      on its changeset so the operator gets `{:error, changeset}` (a form error)
      instead of an `Ecto.ConstraintError`/500.
    * `router_use_cases.fallback_model_id`, `router_configs.{decision,default,baseline}_model_id`
      — `ON DELETE NILIFY ALL`. Those are optional pointers: losing the model
      must fall back to the next link of the chain (per-use-case fallback →
      `router_configs.default_model_id`), never brick the configuration or
      block a delete.

  ## Singleton config

  `router_configs` is a singleton and the database enforces it: `id` is pinned
  to one sentinel uuid by `router_configs_singleton_check`, so a second row
  cannot be inserted even by a bug or a seed run twice. `Config.ensure!/0` is
  the only writer of that id.

  Reversible: `down/0` drops the tables in reverse dependency order.
  """

  use Ecto.Migration

  # Sentinel id of the singleton `router_configs` row (see the moduledoc).
  @config_singleton_id "a750d0c0-0000-4000-8000-000000000001"

  def up do
    create table(:router_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Kill switch: `false` answers 503 router_disabled before touching any
      # provider, so shipping the tables never turns the router on.
      add :enabled, :boolean, null: false, default: false

      # Decision engine block.
      add :policy, :string, null: false, default: "balanced"
      add :decision_timeout_ms, :integer, null: false, default: 800
      add :decision_context_chars, :integer, null: false, default: 1200
      add :fast_path_max_tokens, :integer, null: false, default: 400
      add :sticky_ttl_seconds, :integer, null: false, default: 900
      add :lock_tool_loops, :boolean, null: false, default: true
      add :charge_decision_to_subject, :boolean, null: false, default: true

      # Optional model pointers — nilify on delete (see the moduledoc).
      add :decision_model_id, references(:models, type: :binary_id, on_delete: :nilify_all)
      add :default_model_id, references(:models, type: :binary_id, on_delete: :nilify_all)
      add :baseline_model_id, references(:models, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(
             :router_configs,
             :router_configs_singleton_check,
             check: "id = '#{@config_singleton_id}'::uuid"
           )

    create table(:router_use_cases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Stable slug the presets and the client-facing docs refer to
      # ("coding_implement"). Never rewritten by the preset seeder.
      add :key, :string, null: false
      add :name, :string, null: false
      add :description, :text

      # Dispatch hints: what the use case is about, so a rule or a classifier
      # prompt can talk about specialties instead of model names.
      add :tags, {:array, :string}, null: false, default: []

      # Hard capability requirements: a candidate that cannot honour one of
      # these is discarded by the pre-filter before any classifier runs.
      add :requires_tools, :boolean, null: false, default: false
      add :requires_vision, :boolean, null: false, default: false
      add :requires_structured_output, :boolean, null: false, default: false

      # Selection policy of this specialty.
      add :critical_accuracy, :boolean, null: false, default: false
      add :allow_downgrade, :boolean, null: false, default: true
      add :pin_session, :boolean, null: false, default: true

      # Prompt-saving knobs (nil = the gateway default).
      add :keep_last_n_images, :integer
      add :max_history_turns, :integer
      add :compact_json, :boolean, null: false, default: false
      add :stale_tool_trim_threshold_pct, :integer

      add :priority, :integer, null: false, default: 100
      add :enabled, :boolean, null: false, default: true

      # Per-use-case fallback; nil falls through to `router_configs.default_model_id`.
      add :fallback_model_id, references(:models, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # The preset seeder upserts by key (`ON CONFLICT (key) DO NOTHING`), and the
    # key is the public identity of the use case.
    create unique_index(:router_use_cases, [:key], name: :router_use_cases_key_unique_index)

    create index(:router_use_cases, [:enabled], name: :router_use_cases_enabled_index)

    create constraint(
             :router_use_cases,
             :router_use_cases_stale_tool_trim_pct_check,
             check:
               "stale_tool_trim_threshold_pct IS NULL OR (stale_tool_trim_threshold_pct >= 0 AND stale_tool_trim_threshold_pct <= 100)"
           )

    create table(:router_use_case_models, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :router_use_case_id,
          references(:router_use_cases, type: :binary_id, on_delete: :delete_all),
          null: false

      # RESTRICT + the changeset guard in `Providers.delete_model/1`.
      add :target_model_id, references(:models, type: :binary_id, on_delete: :restrict),
        null: false

      add :effort_tier, :string, null: false, default: "any"
      add :effort_override, :string

      # Which requirement slots this particular model covers.
      add :supports_tools, :boolean, null: false, default: false
      add :supports_vision, :boolean, null: false, default: false
      add :supports_structured_output, :boolean, null: false, default: false

      # Classifier floor for this destination (0..1).
      add :min_confidence, :numeric, precision: 4, scale: 3

      add :tags, {:array, :string}, null: false, default: []
      add :flags, :map, null: false, default: %{}
      add :priority, :integer, null: false, default: 100
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    # One binding per (use case, model, tier): re-binding replaces the flags.
    create unique_index(
             :router_use_case_models,
             [:router_use_case_id, :target_model_id, :effort_tier],
             name: :router_use_case_models_use_case_target_tier_unique_index
           )

    # Postgres does not index FK columns on its own: without this, the RESTRICT
    # check on every `models` delete would seq-scan the bindings table.
    create index(:router_use_case_models, [:target_model_id],
             name: :router_use_case_models_target_model_id_index
           )

    create constraint(
             :router_use_case_models,
             :router_use_case_models_effort_tier_check,
             check: "effort_tier IN ('low', 'medium', 'high', 'any')"
           )

    create constraint(
             :router_use_case_models,
             :router_use_case_models_effort_override_check,
             check: "effort_override IS NULL OR effort_override IN ('low', 'medium', 'high')"
           )

    create constraint(
             :router_use_case_models,
             :router_use_case_models_min_confidence_check,
             check: "min_confidence IS NULL OR (min_confidence >= 0 AND min_confidence <= 1)"
           )

    create table(:router_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, null: false
      add :description, :text
      add :priority, :integer, null: false, default: 100
      add :enabled, :boolean, null: false, default: true

      # Operator-owned match conditions, validated by
      # `Tokengate.SmartRouter.Rule` before it reaches jsonb.
      add :match_conditions, :map, null: false, default: %{}

      add :action, :string, null: false

      # Use-case keys (not ids): a rule outlives a dropped-and-reseeded preset.
      add :target_use_case_keys, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:router_rules, [:name], name: :router_rules_name_unique_index)

    create constraint(
             :router_rules,
             :router_rules_action_check,
             check: "action IN ('force_use_case', 'restrict_use_cases')"
           )
  end

  def down do
    drop table(:router_rules)
    drop table(:router_use_case_models)
    drop table(:router_use_cases)
    drop table(:router_configs)
  end
end
