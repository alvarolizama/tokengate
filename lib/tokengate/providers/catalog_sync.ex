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
  (providers and labs), so this is the single entry point that makes a fresh
  instance usable.

  Idempotent; failures are logged, not raised (the app must boot).
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Tokengate.Providers.{Catalog, CatalogProvider, CatalogSeed, Provider}
  alias Tokengate.Repo

  def sync do
    CatalogSeed.seed_if_empty()
    CatalogSeed.seed_labs_if_empty()
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
      capabilities: Catalog.capabilities(entry.key),
      # Billing is a code label; a provider without one is pay-per-token.
      billing_type: Catalog.billing(entry.key) || "pay_per_token"
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
