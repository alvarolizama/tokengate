defmodule Tokengate.Repo.Migrations.ModelsDevCatalog do
  use Ecto.Migration

  @moduledoc """
  Moves the provider catalog from a compile-time list to a mirror of
  models.dev, and evicts the per-service URL overrides.

  ## What changes

    1. `catalog_providers` — new table mirroring models.dev at PROVIDER level
       (`key` = models.dev id, name, base URL, doc, logo, env, npm). Code
       customizations (capabilities, dialect, paths) are keyed by that id and
       applied at read time; this table is the only thing the refresh worker
       writes.
    2. `catalog_sync_state` — singleton row holding the outcome of the last
       refresh (when, how many inserted/updated/stale, and the drift warnings
       for base URLs that changed under an in-use builtin).
    3. `providers.doc_url` / `providers.logo_url` — materialized identity for
       the provider cards (same lifecycle as name/base_url: stamped by the
       boot sync, locked for builtins).
    4. `providers.chat_url` / `models_url` / `embeddings_url` — DROPPED. Paths
       are code now: the dialect adapter derives them from the base URL and
       `Catalog.path_suffix/2` carries the per-provider exceptions.
    5. Builtin keys re-keyed to their models.dev id (1:1, matched by
       normalized base URL before this migration was written).
  """

  # old catalog key => models.dev id. Verified by normalized base URL:
  # every pair below pointed at the same base URL at migration time.
  @renames %{
    "fireworks" => "fireworks-ai",
    "qwen_cloud" => "alibaba-cn",
    "qwen_cloud_token_plan" => "alibaba-token-plan",
    "opencode_zen" => "opencode",
    "opencode_go" => "opencode-go",
    "kimi" => "moonshotai",
    "kimi_code" => "kimi-for-coding",
    "zai" => "zai",
    "zai_coding_plan" => "zai-coding-plan",
    "openrouter" => "openrouter"
  }

  def up do
    create table(:catalog_providers, primary_key: false) do
      add :key, :string, primary_key: true, null: false
      add :name, :string
      add :base_url, :string
      add :doc_url, :string
      add :logo_url, :string
      add :env, {:array, :string}, null: false, default: []
      add :npm, :string
      # "active" = present upstream. "stale" = gone from models.dev: marked,
      # never deleted (a materialized provider row may be serving traffic).
      add :status, :string, null: false, default: "active"
      # Hash of the upstream provider payload: lets the refresh skip
      # unchanged rows and lets the UI show what actually moved.
      add :fingerprint, :string
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:catalog_providers, [:status])

    create table(:catalog_sync_state, primary_key: false) do
      add :id, :integer, primary_key: true
      add :synced_at, :utc_datetime
      add :source, :string
      add :inserted, :integer, null: false, default: 0
      add :updated, :integer, null: false, default: 0
      add :unchanged, :integer, null: false, default: 0
      add :stale, :integer, null: false, default: 0
      add :error, :string
      # [%{"key" => ..., "from" => ..., "to" => ...}] — base URL moved under a
      # builtin that already has credentials.
      add :warnings, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    execute(
      "INSERT INTO catalog_sync_state (id, inserted, updated, unchanged, stale, warnings, inserted_at, updated_at) VALUES (1, 0, 0, 0, 0, '{}', now(), now())"
    )

    alter table(:providers) do
      add :doc_url, :string
      add :logo_url, :string

      remove :chat_url, :string
      remove :models_url, :string
      remove :embeddings_url, :string
    end

    # Re-key builtins to their models.dev id. Guarded so a row can never be
    # renamed onto an id that already exists (the partial unique index on key
    # would raise), and scoped to builtins so customs are untouched.
    # `repo().query!/2` is the documented params form for raw SQL here.
    for {old_key, new_key} <- @renames, old_key != new_key do
      repo().query!(
        """
        UPDATE providers SET key = $1
        WHERE key = $2
          AND source = 'builtin'
          AND NOT EXISTS (SELECT 1 FROM providers WHERE key = $1)
        """,
        [new_key, old_key]
      )
    end

    # Pre-flight: after the renames, one builtin row per models.dev id at most.
    execute("""
    DO $$
    DECLARE dupes integer;
    BEGIN
      SELECT count(*) INTO dupes FROM (
        SELECT key FROM providers WHERE source = 'builtin' AND key IS NOT NULL
        GROUP BY key HAVING count(*) > 1
      ) d;

      IF dupes > 0 THEN
        RAISE EXCEPTION 'duplicate builtin keys after re-key: % group(s)', dupes;
      END IF;
    END $$;
    """)
  end

  def down do
    alter table(:providers) do
      add :chat_url, :string
      add :models_url, :string
      add :embeddings_url, :string

      remove :doc_url
      remove :logo_url
    end

    for {old_key, new_key} <- @renames, old_key != new_key do
      repo().query!(
        """
        UPDATE providers SET key = $1
        WHERE key = $2
          AND source = 'builtin'
          AND NOT EXISTS (SELECT 1 FROM providers WHERE key = $1)
        """,
        [old_key, new_key]
      )
    end

    drop table(:catalog_sync_state)
    drop table(:catalog_providers)
  end
end
