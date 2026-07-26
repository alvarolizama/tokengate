defmodule Tokengate.Providers.AliasProvider do
  @moduledoc """
  Joins a ModelAlias to a Provider, specifying the actual model name
  at the provider (`provider_model`), optional subscription routing,
  priority/weight for routing strategies, and enabled flag.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "alias_providers" do
    field :provider_model, :string
    field :priority, :integer
    field :weight, :integer
    field :enabled, :boolean, default: true

    belongs_to :model_alias, Tokengate.Providers.ModelAlias
    belongs_to :provider, Tokengate.Providers.Provider
    belongs_to :subscription, Tokengate.Providers.Subscription

    has_many :model_pricing, Tokengate.Providers.ModelPricing

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(alias_provider, attrs) do
    alias_provider
    |> cast(attrs, [
      :model_alias_id,
      :provider_id,
      :provider_model,
      :subscription_id,
      :priority,
      :weight,
      :enabled
    ])
    |> validate_required([:model_alias_id, :provider_id, :provider_model, :enabled])
    |> foreign_key_constraint(:model_alias_id)
    |> foreign_key_constraint(:provider_id)
    |> foreign_key_constraint(:subscription_id)
  end
end
