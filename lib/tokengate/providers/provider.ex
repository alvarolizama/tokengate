defmodule Tokengate.Providers.Provider do
  @moduledoc """
  A provider is an upstream LLM API (OpenAI, Anthropic, etc.) that
  TokenGate routes requests to.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @billing_types ~w(pay_per_token subscription)

  schema "providers" do
    field :name, :string
    field :base_url, :string
    field :billing_type, :string
    field :track_real_usage, :boolean, default: false

    has_many :credentials, Tokengate.Providers.Credential
    has_many :subscriptions, Tokengate.Providers.Subscription
    has_many :alias_providers, Tokengate.Providers.AliasProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :base_url, :billing_type, :track_real_usage])
    |> validate_required([:name, :base_url, :billing_type])
    |> validate_inclusion(:billing_type, @billing_types)
    |> unique_constraint(:name)
  end

  @doc "List of valid billing_type values"
  def billing_types, do: @billing_types
end
