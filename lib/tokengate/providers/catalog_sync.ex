defmodule Tokengate.Providers.CatalogSync do
  @moduledoc """
  Boot-time sync between the compile-time catalog and the `providers`
  table. Runs once after the Repo starts (temporary task in the app
  supervision tree).

  Per builtin entry, by `key`:

    * row exists → update name/base_url/dialect/capabilities from the
      catalog (base URL changes released with the catalog land here).
    * row missing → insert.

  Never touches `source: "custom"` rows — those are operator-owned.
  Idempotent; failures are logged, not raised (the app must boot).
  """

  require Logger

  alias Tokengate.Providers.Catalog
  alias Tokengate.Repo

  def sync do
    Enum.each(Catalog.all(), fn entry ->
      case Repo.get_by(Tokengate.Providers.Provider, key: entry.key) do
        nil ->
          %Tokengate.Providers.Provider{}
          |> Ecto.Changeset.change(
            key: entry.key,
            name: entry.name,
            base_url: entry.base_url,
            source: "builtin",
            dialect: entry.dialect,
            capabilities: entry.capabilities,
            status: "active"
          )
          |> Repo.insert()

        provider ->
          provider
          |> Ecto.Changeset.change(
            name: entry.name,
            base_url: entry.base_url,
            dialect: entry.dialect,
            capabilities: entry.capabilities
          )
          |> Repo.update()
      end
    end)

    :ok
  rescue
    e -> Logger.error("[catalog sync] failed: #{Exception.message(e)}")
  end

  def child_spec(_arg) do
    Supervisor.child_spec(
      {Task, fn -> sync() end},
      id: __MODULE__,
      restart: :temporary
    )
  end
end
