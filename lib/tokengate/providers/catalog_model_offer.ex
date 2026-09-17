defmodule Tokengate.Providers.CatalogModelOffer do
  @moduledoc """
  The fact that a provider serves a model: one row per (provider, model).

  Remote data, refreshed by `CatalogRefreshWorker` from the per-provider `models`
  map of models.dev's `/api.json`. It is what the model picker needs and what the
  canonical list cannot give:

    * **who serves this model** — the picker lists the providers of a model, which
      is exactly the set of rows this table holds for that `model_key`;
    * **the id to send upstream** — `provider_model`, published per provider
      (`"accounts/fireworks/routers/kimi-latest"`, `"@cf/meta/llama-3.1-8b-instruct-fp8"`);
    * **the price that provider charges** — `cost_*` (USD per 1M tokens), with the
      context tiers upstream publishes in `tiers`. It is used to prefill the
      operator's manual pricing fallback on `model_providers`, never to bill:
      billing reads upstream-reported cost first.

  Rows are never deleted: an offer that disappears upstream is marked
  `status: "stale"` — an operator may be routing through it already.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active stale)

  schema "catalog_model_offers" do
    # models.dev provider id (joins `catalog_providers.key` / `providers.key`).
    field :provider_key, :string
    # models.dev model id (joins `catalog_models.key`).
    field :model_key, :string
    field :provider_model, :string
    field :cost_input, :decimal
    field :cost_output, :decimal
    field :cost_cache_read, :decimal
    field :cost_cache_write, :decimal
    field :tiers, {:array, :map}, default: []
    field :limit_context, :integer
    field :limit_output, :integer
    # What upstream says about this provider's entry: "stable" | "beta" |
    # "deprecated". Surfaced in the picker so a deprecated lane is an informed
    # choice, not a surprise.
    field :lifecycle, :string, default: "stable"
    field :experimental, :boolean, default: false
    field :status, :string, default: "active"
    field :fingerprint, :string
    field :fetched_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @remote_fields [
    :provider_key,
    :model_key,
    :provider_model,
    :cost_input,
    :cost_output,
    :cost_cache_read,
    :cost_cache_write,
    :tiers,
    :limit_context,
    :limit_output,
    :lifecycle,
    :experimental
  ]

  @doc "Valid status values."
  def statuses, do: @statuses

  @doc """
  Digest of the upstream-visible fields of an offer.

  Two refreshes that see the same provider/model pair produce the same
  fingerprint, so an unchanged offer is one comparison.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(entry) when is_map(entry) do
    payload = Enum.map(@remote_fields, fn field -> {field, Map.get(entry, field)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc false
  def changeset(offer, attrs) do
    offer
    |> cast(attrs, @remote_fields ++ [:status, :fingerprint, :fetched_at])
    |> validate_required([:provider_key, :model_key])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:provider_key, :model_key])
  end

  @doc "Changeset used by the refresh and the seed (see `CatalogModel.remote_changeset/2`)."
  def remote_changeset(offer, attrs), do: changeset(offer, attrs)
end
