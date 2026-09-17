defmodule Tokengate.Providers.CatalogModel do
  @moduledoc """
  Mirror of models.dev at MODEL level (one row per model id).

  Remote data, refreshed asynchronously by `CatalogRefreshWorker` and seeded
  from the vendored snapshot on a fresh database — the same contract as
  `CatalogProvider` and `Lab`:

    * `key` is the models.dev model id (`"openai/gpt-5-nano"`, `"glm-5.2"`,
      `"accounts/fireworks/routers/kimi-latest"`) and is what the operator's
      `models.name` is offered as a default.
    * `canonical` distinguishes the models `/models.json` publishes from the ones
      only a provider lists: upstream has 403 canonical entries, while the
      supported providers serve ~3000 distinct ids, so the picker cannot be
      built from the canonical list alone.
    * `lab_key` is the prefix of the id (soft link to `labs`: a provider may
      publish an id whose prefix has no lab row).
    * `fingerprint` is a digest of exactly the upstream-visible fields, so the
      refresh decides insert / update / unchanged without a deep diff.

  Rows are never deleted: a model that disappears from models.dev is marked
  `status: "stale"` (`#{inspect(~w(active stale))}`), because an operator may
  already have a `model_providers` row serving traffic through it.

  Costs on this row are the CANONICAL market prices (display-only, like
  `models.market_*`). The price a provider charges for a specific model lives on
  `CatalogModelOffer`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @statuses ~w(active stale)
  @features ~w(reasoning tool_call attachment structured_output open_weights temperature)

  schema "catalog_models" do
    field :name, :string
    field :lab_key, :string
    field :description, :string
    field :canonical, :boolean, default: false
    field :context_limit, :integer
    field :output_limit, :integer
    field :cost_input, :decimal
    field :cost_output, :decimal
    field :cost_cache_read, :decimal
    field :cost_cache_write, :decimal
    field :modalities, :map, default: %{}
    field :features, {:array, :string}, default: []
    field :release_date, :string
    field :last_updated, :string
    field :license, :string
    field :status, :string, default: "active"
    field :fingerprint, :string
    field :fetched_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  # The upstream-visible half: everything the refresh copies verbatim.
  @remote_fields [
    :key,
    :name,
    :lab_key,
    :description,
    :canonical,
    :context_limit,
    :output_limit,
    :cost_input,
    :cost_output,
    :cost_cache_read,
    :cost_cache_write,
    :modalities,
    :features,
    :release_date,
    :last_updated,
    :license
  ]

  @doc "Valid status values."
  def statuses, do: @statuses

  @doc "Feature names the catalog may record."
  def features, do: @features

  @doc """
  Digest of the upstream-visible fields of an entry.

  Takes a struct or a map with atom keys. Two refreshes that see the same entry
  produce the same fingerprint, so an unchanged row is one comparison.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(entry) when is_map(entry) do
    payload = Enum.map(@remote_fields, fn field -> {field, Map.get(entry, field)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @remote_fields ++ [:status, :fingerprint, :fetched_at])
    |> validate_required([:key])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Changeset used by the refresh and the seed — the same cast as `changeset/2`,
  kept as a named seam so the remote writer is obvious at the call sites.
  """
  def remote_changeset(entry, attrs), do: changeset(entry, attrs)
end
