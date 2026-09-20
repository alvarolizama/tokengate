defmodule Tokengate.Providers.CatalogSeed do
  @moduledoc """
  Seeds the catalog mirrors from the vendored models.dev snapshots.

  Runs at boot (`CatalogSync`) and only when the target mirror is EMPTY: from
  then on the tables are owned by `CatalogRefreshWorker`. The snapshots exist
  so a fresh instance has a working catalog without network access, and so a
  failed fetch never leaves the catalog blank.

  Every half is idempotent, and none of them ever overwrites what a refresh
  brought:

    * `seed_if_empty/0` seeds `catalog_providers` (the provider mirror).
    * `seed_labs_if_empty/0` seeds `labs` (the lab catalog), and only counts and
      writes `source: "builtin"` rows — a custom lab says nothing about whether
      the models.dev half has been seeded.

  El nivel MODELO de models.dev no se siembra aquí: ese espejo se retiró y el
  alta lista los modelos del proveedor en vivo.

  The counters on `catalog_sync_state` mean "written by the catalog sync that
  just ran", which on a fresh boot is this seed; the refresh owns the same
  counters from then on.
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers.{
    Catalog,
    CatalogProvider,
    CatalogSyncState,
    Lab,
    LabCatalog
  }

  alias Tokengate.Repo

  @doc """
  Inserts the whole provider snapshot when `catalog_providers` is empty.
  Returns the number of rows inserted (0 when the mirror already had data).
  """
  @spec seed_if_empty() :: non_neg_integer()
  def seed_if_empty do
    if Repo.aggregate(CatalogProvider, :count) == 0 do
      seed()
    else
      0
    end
  end

  @doc "Forces a provider seed from the snapshot (skips rows that already exist)."
  @spec seed() :: non_neg_integer()
  def seed do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Catalog.snapshot()
      |> Enum.map(fn entry ->
        entry
        |> Map.merge(%{
          status: "active",
          fetched_at: now,
          # insert_all does not fill the schema timestamps.
          inserted_at: now,
          updated_at: now
        })
        |> Map.put(:fingerprint, CatalogProvider.fingerprint(entry))
      end)

    {count, _} = Repo.insert_all(CatalogProvider, rows, on_conflict: :nothing)

    CatalogSyncState.record(%{
      synced_at: now,
      source: "snapshot",
      inserted: count,
      updated: 0,
      unchanged: 0,
      stale: 0,
      error: nil,
      warnings: []
    })

    Logger.info("[catalog seed] #{count} provider(s) seeded from the vendored snapshot")
    count
  end

  @doc """
  Inserts the whole lab snapshot when `labs` holds no builtin row.

  Returns the number of rows inserted (0 when the models.dev half was already
  seeded).
  """
  @spec seed_labs_if_empty() :: non_neg_integer()
  def seed_labs_if_empty do
    if Repo.aggregate(from(l in Lab, where: l.source == "builtin"), :count) == 0 do
      seed_labs()
    else
      0
    end
  end

  @doc "Forces a lab seed from the snapshot (skips rows that already exist)."
  @spec seed_labs() :: non_neg_integer()
  def seed_labs do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      LabCatalog.snapshot()
      |> Enum.map(fn entry ->
        entry
        |> Map.merge(%{
          source: "builtin",
          status: "active",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        })
        |> Map.put(:fingerprint, Lab.fingerprint(entry))
      end)

    {count, _} = Repo.insert_all(Lab, rows, on_conflict: :nothing)

    # Only the lab counters: `synced_at`/`source` describe the provider half of
    # the same boot, which runs first (see `CatalogSync.sync/0`).
    CatalogSyncState.record(%{labs_inserted: count})

    Logger.info("[catalog seed] #{count} lab(s) seeded from the vendored snapshot")
    count
  end
end
