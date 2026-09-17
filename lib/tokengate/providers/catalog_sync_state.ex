defmodule Tokengate.Providers.CatalogSyncState do
  @moduledoc """
  Singleton row holding the outcome of the last models.dev catalog refresh.

  Read by the maintenance page so an operator can see when the catalog was last
  refreshed, how many providers moved, and — most importantly — the base URLs
  that changed upstream under a builtin that already has credentials
  (`warnings`). Those are applied (the gateway follows upstream), but they are
  the one event that can silently reroute live traffic, so they get surfaced.

  `warnings` is a list of `%{"key" => …, "name" => …, "from" => …, "to" => …,
  "credentials" => n}`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Tokengate.Repo

  # Fixed primary key of the single singleton row (seeded in a migration).
  @singleton_id 1

  schema "catalog_sync_state" do
    field :synced_at, :utc_datetime
    # "models.dev" (live fetch) or "snapshot" (vendored seed).
    field :source, :string
    field :inserted, :integer, default: 0
    field :updated, :integer, default: 0
    field :unchanged, :integer, default: 0
    field :stale, :integer, default: 0
    # The lab half of the same run (derived from the same payloads). Labs have
    # no materialization step, so there is no "skipped" equivalent.
    field :labs_inserted, :integer, default: 0
    field :labs_updated, :integer, default: 0
    field :labs_stale, :integer, default: 0
    # The model half: the model dimension (`catalog_models`) and the provider ×
    # model offers (`catalog_model_offers`), counted apart so a new model is
    # distinguishable from a new lane to a model that already existed.
    field :models_inserted, :integer, default: 0
    field :models_updated, :integer, default: 0
    field :models_stale, :integer, default: 0
    field :offers_inserted, :integer, default: 0
    field :offers_updated, :integer, default: 0
    field :offers_stale, :integer, default: 0
    field :error, :string
    field :warnings, {:array, :map}, default: []

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :synced_at,
      :source,
      :inserted,
      :updated,
      :unchanged,
      :stale,
      :labs_inserted,
      :labs_updated,
      :labs_stale,
      :models_inserted,
      :models_updated,
      :models_stale,
      :offers_inserted,
      :offers_updated,
      :offers_stale,
      :error,
      :warnings
    ])
  end

  @doc "The singleton row (created by the migration)."
  def get, do: Repo.get(__MODULE__, @singleton_id)

  @doc "The singleton row, raising when it is missing."
  def get!, do: Repo.get!(__MODULE__, @singleton_id)

  @doc "Overwrites the singleton row with the outcome of a refresh run."
  def record(attrs) do
    get!()
    |> changeset(attrs)
    |> Repo.update()
  end
end
