defmodule Tokengate.Providers.CatalogProvider do
  @moduledoc """
  Mirror of models.dev at PROVIDER level (one row per provider, no models).

  This is remote data, refreshed asynchronously by
  `Tokengate.Providers.CatalogRefreshWorker`:

    * `key` is the models.dev id (`"openrouter"`, `"fireworks-ai"`, …) and is
      the join key to the code customizations in `Tokengate.Providers.Catalog`.
    * `name`, `base_url`, `doc_url`, `logo_url`, `env` and `npm` are copied
      verbatim from upstream (base URL trailing slash trimmed).
    * `fingerprint` is a digest of exactly those fields: the refresh compares
      it to decide insert / update / unchanged without a deep diff.

  Rows are never deleted: a provider that disappears from models.dev is marked
  `status: "stale"` (`#{inspect(~w(active stale))}`), because a materialized
  `providers` row may be serving traffic from credentials.

  Code, not this table, owns the extra properties the operator needs
  (capabilities, dialect, paths, quirks) — see `Catalog`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @statuses ~w(active stale)

  schema "catalog_providers" do
    field :name, :string
    field :base_url, :string
    field :doc_url, :string
    field :logo_url, :string
    field :env, {:array, :string}, default: []
    field :npm, :string
    field :status, :string, default: "active"
    field :fingerprint, :string
    field :fetched_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Valid status values."
  def statuses, do: @statuses

  @doc """
  Digest of the upstream-visible fields of an entry.

  Takes a struct or a map with atom keys and returns a short hex string. Two
  refreshes that see the same provider produce the same fingerprint, so an
  unchanged row is a single comparison.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(entry) when is_map(entry) do
    payload =
      Enum.map(
        [:name, :base_url, :doc_url, :logo_url, :env, :npm],
        fn field -> {field, Map.get(entry, field)} end
      )

    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :key,
      :name,
      :base_url,
      :doc_url,
      :logo_url,
      :env,
      :npm,
      :status,
      :fingerprint,
      :fetched_at
    ])
    |> validate_required([:key, :name])
    |> validate_inclusion(:status, @statuses)
  end
end
