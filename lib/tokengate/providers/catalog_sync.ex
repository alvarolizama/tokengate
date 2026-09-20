defmodule Tokengate.Providers.CatalogSync do
  @moduledoc """
  Boot-time materialization of the provider catalog.

  Per mirror row in `catalog_providers` (models.dev identity + code
  customizations), it upserts the matching `providers` row by `key`:

    * `name`, `base_url`, `doc_url`, `logo_url`, `dialect` and `capabilities`
      are stamped from the catalog (`Catalog.base_url/1` applies the code
      override when a provider declares one);
    * a provider the gateway cannot serve (no base URL, or an npm package with
      no dialect) is SKIPPED — no row is materialized until it is supported;
    * rows are only written when a value actually changed, so a boot with an
      unchanged catalog issues zero updates;
    * `source: "custom"` rows are never touched, and nothing is ever deleted
      (a materialized provider may be serving traffic).

  Also seeds the mirrors from the vendored snapshots when they are empty
  (providers and labs), so `sync/0` is the single entry point that makes a fresh
  instance usable.

  ## Two entry points, on purpose

  `sync/0` is the BOOT path: it seeds the two mirrors and then materializes.
  `materialize/0` is the REFRESH path (called by `CatalogRefreshWorker` after it
  wrote the mirror): it materializes only, and seeds nothing.

  The split matters because seeding from a snapshot is a boot concern. A refresh
  that seeded would write rows the live payload it just downloaded is about to
  describe — the operator would see counters for a run that wrote nothing (the
  snapshot did), and the refresh's own insert path would never run on a fresh
  database.

  Idempotent; failures are logged, not raised (the app must boot).
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers.{
    Catalog,
    CatalogProvider,
    CatalogSeed,
    Provider
  }

  alias Tokengate.Repo

  @doc "Boot path: seed the mirrors from the vendored snapshots, then materialize."
  def sync do
    CatalogSeed.seed_if_empty()
    CatalogSeed.seed_labs_if_empty()
    ensure_code_providers()
    materialize()
  end

  @doc """
  Materialize the mirror into the operator's `providers` table.

  Called at boot (after the seeds, via `sync/0`) and by the refresh worker right
  after it wrote the mirror — that is what makes a base URL fix land on a running
  instance without a restart. Seeds nothing: see the moduledoc.
  """
  def materialize do
    entries = Repo.all(from c in CatalogProvider, order_by: [asc: c.key])

    {materialized, skipped} =
      Enum.reduce(entries, {0, 0}, fn entry, {ok, skip} ->
        case materialize(entry) do
          :ok -> {ok + 1, skip}
          :skipped -> {ok, skip + 1}
        end
      end)

    if skipped > 0 do
      Logger.debug("[catalog sync] #{materialized} provider(s) materialized, #{skipped} skipped")
    end

    :ok
  rescue
    e -> Logger.error("[catalog sync] failed: #{Exception.message(e)}")
  end

  @doc """
  Upserts the CODE-OWNED provider rows into the mirror.

  A provider models.dev does not publish at all (its row, name, base URL and
  logo exist only in `Catalog.@code_providers`) still has to reach
  `catalog_providers`, because that mirror is the single input `materialize/0`
  reads.

  Two reasons this is not the vendored snapshot's job:

    * `CatalogSeed.seed_if_empty/0` only seeds an EMPTY table, so a running
      instance — which never goes back to empty — would never see the row;
    * `priv/models_dev/providers.json` is read at COMPILE time, so it is baked
      into the release image and a hand edit drifts from the code.

  Idempotent on the same rule as `apply_entries/1`: a row whose fingerprint
  already matches is not written, so an unchanged boot issues zero updates.
  Never raises — the app must boot.
  """
  @spec ensure_code_providers() :: :ok
  def ensure_code_providers do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(Catalog.code_providers(), fn entry ->
      attrs =
        entry
        |> Map.merge(%{fetched_at: now, status: "active"})
        |> Map.put(:fingerprint, CatalogProvider.fingerprint(entry))

      case Repo.get(CatalogProvider, entry.key) do
        nil ->
          %CatalogProvider{} |> CatalogProvider.changeset(attrs) |> Repo.insert()

        %CatalogProvider{fingerprint: fingerprint, status: "active"}
        when fingerprint == attrs.fingerprint ->
          :ok

        %CatalogProvider{} = row ->
          row |> CatalogProvider.changeset(attrs) |> Repo.update()
      end
    end)

    :ok
  rescue
    e ->
      Logger.error("[catalog sync] code-owned providers failed: #{Exception.message(e)}")
      :ok
  end

  # The lab mirror: upserts builtin rows from the vendored snapshot. Kept as a
  # separate entry point so `sync/0` stays the boot path for providers; the lab
  # half is covered by the seed + the refresh worker.
  def sync_labs do
    CatalogSeed.seed_labs_if_empty()
    :ok
  rescue
    e -> Logger.error("[catalog sync] labs failed: #{Exception.message(e)}")
  end

  # Only catalog rows still present upstream materialize. A "stale" row (gone
  # from models.dev) keeps whatever `providers` row it already has — deleting
  # it would cascade credentials.
  defp materialize(%CatalogProvider{status: "stale"}), do: :skipped

  defp materialize(%CatalogProvider{} = entry) do
    case Catalog.unsupported_reason(entry) do
      nil ->
        upsert(entry)
        :ok

      reason ->
        Logger.debug("[catalog sync] #{entry.key} not materialized: #{reason}")
        :skipped
    end
  end

  defp upsert(entry) do
    {:ok, dialect} = Catalog.dialect(entry)

    attrs = %{
      name: entry.name,
      base_url: Catalog.base_url(entry),
      doc_url: entry.doc_url,
      logo_url: entry.logo_url,
      dialect: dialect,
      capabilities: Catalog.capabilities(entry.key)
    }

    case Repo.get_by(Provider, key: entry.key) do
      nil ->
        %Provider{}
        |> Ecto.Changeset.change(
          Map.merge(attrs, %{key: entry.key, source: "builtin", status: "active"})
        )
        |> Repo.insert()

      # A custom row that happens to carry this key is operator-owned.
      %Provider{source: "custom"} ->
        :ok

      %Provider{} = provider ->
        changes = Enum.reject(attrs, fn {field, value} -> Map.get(provider, field) == value end)

        if changes == [] do
          :ok
        else
          provider
          |> Ecto.Changeset.change(Map.new(changes))
          |> Repo.update()
        end
    end
  end

  def child_spec(_arg) do
    Supervisor.child_spec(
      {Task, fn -> sync() end},
      id: __MODULE__,
      restart: :temporary
    )
  end
end
