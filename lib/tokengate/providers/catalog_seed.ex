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
    * `seed_models_if_empty/0` seeds `catalog_models` (the model dimension) and
      `catalog_model_offers` (provider × model), from ONE vendored file that
      holds both halves — they are derived together and must land together.

  The counters on `catalog_sync_state` mean "written by the catalog sync that
  just ran", which on a fresh boot is this seed; the refresh owns the same
  counters from then on.
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers.{
    Catalog,
    CatalogModel,
    CatalogModelOffer,
    CatalogProvider,
    CatalogSyncState,
    Lab,
    LabCatalog,
    ModelCatalog
  }

  alias Tokengate.Repo

  # A single `insert_all` over the model mirror would blow Postgres' 65535
  # bind-parameter ceiling (the offers alone are ~6000 rows), so rows go in
  # batches.
  @insert_chunk_size 500

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

  @doc """
  Inserts the whole model snapshot (models + offers) when `catalog_models` is
  empty.

  Returns the number of rows inserted; 0 when the model mirror already had data
  or when the vendored snapshot is absent (an instance can still boot, it just
  waits for the first refresh).
  """
  @spec seed_models_if_empty() :: non_neg_integer()
  def seed_models_if_empty do
    if Repo.aggregate(CatalogModel, :count) == 0 do
      seed_models()
    else
      0
    end
  end

  @doc "Forces a model seed from the snapshot (skips rows that already exist)."
  @spec seed_models() :: non_neg_integer()
  def seed_models do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %{models: models, offers: offers} = ModelCatalog.snapshot()

    model_rows =
      Enum.map(models, fn attrs ->
        attrs
        |> Map.merge(%{status: "active", fetched_at: now, inserted_at: now, updated_at: now})
        |> Map.put(:fingerprint, CatalogModel.fingerprint(attrs))
      end)

    offer_rows =
      Enum.map(offers, fn attrs ->
        attrs
        |> Map.merge(%{
          # A uuid primary key is not autogenerated by insert_all.
          id: Ecto.UUID.generate(),
          status: "active",
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        })
        |> Map.put(:fingerprint, CatalogModelOffer.fingerprint(attrs))
      end)

    model_count = insert_chunks(CatalogModel, model_rows)
    offer_count = insert_chunks(CatalogModelOffer, offer_rows)

    CatalogSyncState.record(%{models_inserted: model_count, offers_inserted: offer_count})

    Logger.info(
      "[catalog seed] #{model_count} model(s) and #{offer_count} offer(s) seeded from the vendored snapshot"
    )

    model_count + offer_count
  end

  defp insert_chunks(schema, rows) do
    rows
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce(0, fn chunk, count ->
      {inserted, _} = Repo.insert_all(schema, chunk, on_conflict: :nothing)
      count + inserted
    end)
  end
end
