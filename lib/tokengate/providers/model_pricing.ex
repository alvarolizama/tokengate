defmodule Tokengate.Providers.ModelPricing do
  @moduledoc """
  Pricing tiers for an ModelProvider, effective from a given datetime.
  Only meaningful when the provider is `pay_per_token` — this is
  validated at the context layer, not the DB.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "model_pricing" do
    field :input_price_per_1m, :decimal
    field :output_price_per_1m, :decimal
    field :cache_read_price_per_1m, :decimal
    field :cache_creation_price_per_1m, :decimal
    field :effective_from, :utc_datetime

    belongs_to :model_provider, Tokengate.Providers.ModelProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model_pricing, attrs) do
    model_pricing
    |> cast(attrs, [
      :model_provider_id,
      :input_price_per_1m,
      :output_price_per_1m,
      :cache_read_price_per_1m,
      :cache_creation_price_per_1m,
      :effective_from
    ])
    |> validate_required([
      :model_provider_id,
      :input_price_per_1m,
      :output_price_per_1m,
      :effective_from
    ])
    |> foreign_key_constraint(:model_provider_id)
    |> validate_number(:input_price_per_1m, greater_than_or_equal_to: 0)
    |> validate_number(:output_price_per_1m, greater_than_or_equal_to: 0)
    |> validate_number(:cache_read_price_per_1m, greater_than_or_equal_to: 0)
    |> validate_number(:cache_creation_price_per_1m, greater_than_or_equal_to: 0)
  end
end
