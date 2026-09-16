defmodule Tokengate.Repo.Migrations.LabsCatalog do
  use Ecto.Migration

  @moduledoc """
  Adds the LAB catalog: the `labs` mirror of models.dev plus the per-run lab
  counters on `catalog_sync_state`.

  ## Why a lab is not a provider

  models.dev publishes no lab endpoint: a lab is the PREFIX of a canonical
  model id (`anthropic/claude-opus-4.7` → lab `anthropic`). The name is the
  provider of that id when there is one (falling back to the capitalized id)
  and the logo is `https://models.dev/logos/labs/{key}.svg`. So the catalog is
  DERIVED from `/models.json` + `/api.json`, not read from a lab payload.

  ## One table, two owners

  `source` splits the rows: `"builtin"` rows are stamped by the refresh
  (`CatalogRefreshWorker`) from models.dev, `"custom"` rows are operator-created
  (a lab the gateway serves that models.dev does not publish — a private
  lab/relay brand). Every write the refresh makes is scoped to
  `source = 'builtin'`, so a refresh can never touch a custom row. That is the
  same guarantee the provider side gets from its mirror/materialized split,
  without needing a second table here.

  `icon` is the fallback mark when there is no `logo_url` (a hero icon name):
  builtins always carry the upstream logo URL, customs may carry an operator
  URL, an icon, or both. It is never written by the refresh.
  """

  def up do
    create table(:labs, primary_key: false) do
      # models.dev lab id: the prefix of the canonical model id. Join key for
      # everything that references a lab.
      add :key, :string, primary_key: true, null: false
      add :name, :string, null: false
      # Remote logo (models.dev for builtins, the operator's URL for customs).
      add :logo_url, :string
      # Hero icon name used when there is no logo. Operator-owned.
      add :icon, :string
      # "builtin" = stamped by the models.dev refresh. "custom" = operator row.
      add :source, :string, null: false, default: "builtin"
      # "active" = present upstream (or an existing custom). "stale" = gone
      # from models.dev: marked, never deleted.
      add :status, :string, null: false, default: "active"
      # Number of canonical models models.dev attributes to this lab. Exact:
      # it is a count over the canonical model list.
      add :model_count, :integer, null: false, default: 0
      # Upstream dates, verbatim ("2026-09-12" — and month-precision values
      # like "2026-09" are legitimate upstream). ISO-8601 strings, so they
      # order correctly as strings and the catalog never invents a day.
      add :last_released, :string
      add :last_updated, :string
      # Hash of the upstream-visible fields: lets a refresh skip unchanged rows.
      add :fingerprint, :string
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:labs, [:source])
    create index(:labs, [:status])

    alter table(:catalog_sync_state) do
      # Lab half of the same refresh run, so the single "last refresh outcome"
      # row stays complete. Providers keep their own counters above.
      add :labs_inserted, :integer, null: false, default: 0
      add :labs_updated, :integer, null: false, default: 0
      add :labs_stale, :integer, null: false, default: 0
    end
  end

  def down do
    alter table(:catalog_sync_state) do
      remove :labs_inserted
      remove :labs_updated
      remove :labs_stale
    end

    drop table(:labs)
  end
end
