defmodule Tokengate.Repo.Migrations.CatalogModels do
  use Ecto.Migration

  @moduledoc """
  Mirror of models.dev at MODEL level, plus the per-provider offer that makes a
  model routable.

  ## What changes

    1. `catalog_models` — one row per model id, remote-owned like
       `catalog_providers` and `labs`. Fields come from two upstream sources:
       `/models.json` (the canonical models: name, description, limits,
       modalities, dates, license, market cost) and, for the ids only a provider
       publishes (`@cf/…`, `accounts/fireworks/routers/…`), that provider's own
       entry. `canonical` says which of the two it is.
    2. `catalog_model_offers` — the FACT: provider `X` serves model `Y`, at which
       `provider_model` id and which cost. Unique on (provider_key, model_key).
       This is what the model picker uses to list "who serves this model".
    3. `catalog_sync_state.models_*` — the model half of the same refresh run.
    4. `models.catalog_model_key` / `models.lab_key` — the link from an operator's
       row back to the catalog entry it was created from (nil = built by hand)
       and to its lab. Both are plain strings with an index, NOT foreign keys: a
       provider can publish an id whose lab prefix has no `labs` row, and a
       missing lab must never block creating a real model.

  Rows are never deleted: a model or offer that disappears upstream is marked
  `status: "stale"`, because an operator's `model_providers` row may already be
  serving traffic through it.
  """

  def up do
    create table(:catalog_models, primary_key: false) do
      add :key, :string, primary_key: true, null: false
      add :name, :string
      # Prefix of the id (`anthropic/claude-opus-4.7` → "anthropic"). Soft link
      # to `labs.key` on purpose — see the moduledoc.
      add :lab_key, :string
      add :description, :text
      # true = published in `/models.json`; false = only a provider lists it.
      add :canonical, :boolean, null: false, default: false
      add :context_limit, :integer
      add :output_limit, :integer
      # Market prices (USD per 1M tokens), canonical entries only. Display-only,
      # exactly like `models.market_*`.
      add :cost_input, :numeric, precision: 12, scale: 6
      add :cost_output, :numeric, precision: 12, scale: 6
      add :cost_cache_read, :numeric, precision: 12, scale: 6
      add :cost_cache_write, :numeric, precision: 12, scale: 6
      add :modalities, :map, null: false, default: %{}
      # Enabled upstream features: reasoning, tool_call, attachment,
      # structured_output, open_weights.
      add :features, {:array, :string}, null: false, default: []
      add :release_date, :string
      add :last_updated, :string
      add :license, :string
      add :status, :string, null: false, default: "active"
      add :fingerprint, :string
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:catalog_models, [:status])
    create index(:catalog_models, [:lab_key])
    create index(:catalog_models, [:canonical])

    # `primary_key: false` + an explicit `:binary_id` id: Ecto's default would
    # create a bigserial integer id, which cannot hold the uuid the schema
    # autogenerates.
    create table(:catalog_model_offers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_key, :string, null: false
      add :model_key, :string, null: false
      # The id to send upstream (models.dev publishes it per provider).
      add :provider_model, :string
      add :cost_input, :numeric, precision: 12, scale: 6
      add :cost_output, :numeric, precision: 12, scale: 6
      add :cost_cache_read, :numeric, precision: 12, scale: 6
      add :cost_cache_write, :numeric, precision: 12, scale: 6
      # Context-tiered pricing, verbatim from upstream:
      # [%{"tier" => %{"type" => "context", "size" => 32000}, "input" => …}]
      add :tiers, {:array, :map}, null: false, default: []
      # Per-provider limit override, when the provider publishes one.
      add :limit_context, :integer
      add :limit_output, :integer
      # Upstream lifecycle for THIS provider's entry: "stable" | "beta" |
      # "deprecated" (models.dev flags 283 deprecations and 73 betas across
      # providers). Only provider entries carry it; canonical rows do not.
      add :lifecycle, :string, null: false, default: "stable"
      add :experimental, :boolean, null: false, default: false
      add :status, :string, null: false, default: "active"
      add :fingerprint, :string
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:catalog_model_offers, [:provider_key, :model_key])
    create index(:catalog_model_offers, [:model_key])
    create index(:catalog_model_offers, [:status])

    alter table(:catalog_sync_state) do
      add :models_inserted, :integer, null: false, default: 0
      add :models_updated, :integer, null: false, default: 0
      add :models_stale, :integer, null: false, default: 0
      # The offer half of the model mirror (provider × model), counted apart so
      # the maintenance page can tell a new model from a new lane to a known one.
      add :offers_inserted, :integer, null: false, default: 0
      add :offers_updated, :integer, null: false, default: 0
      add :offers_stale, :integer, null: false, default: 0
    end

    alter table(:models) do
      # The models.dev id this row was created from (nil = custom by hand).
      add :catalog_model_key, :string
      add :lab_key, :string
    end

    create index(:models, [:catalog_model_key])
    create index(:models, [:lab_key])
  end

  def down do
    drop index(:models, [:lab_key])
    drop index(:models, [:catalog_model_key])

    alter table(:models) do
      remove :catalog_model_key
      remove :lab_key
    end

    alter table(:catalog_sync_state) do
      remove :models_inserted
      remove :models_updated
      remove :models_stale
      remove :offers_inserted
      remove :offers_updated
      remove :offers_stale
    end

    drop table(:catalog_model_offers)
    drop table(:catalog_models)
  end
end
