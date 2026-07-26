defmodule Tokengate.Providers.ModelAlias do
  @moduledoc """
  A model alias is an organization-scoped logical model name that
  maps to one or more provider-backed models (alias_providers).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @routing_strategies ~w(priority round_robin)

  schema "model_aliases" do
    field :name, :string
    field :display_name, :string
    field :market_input_price_per_1m, :decimal
    field :market_output_price_per_1m, :decimal
    field :context_window, :integer
    field :routing_strategy, :string, default: "priority"

    # belongs_to Organization — module ref resolves at runtime;
    # Accounts context is owned by another subagent.
    belongs_to :organization, Tokengate.Accounts.Organization

    has_many :alias_providers, Tokengate.Providers.AliasProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model_alias, attrs) do
    model_alias
    |> cast(attrs, [
      :organization_id,
      :name,
      :display_name,
      :market_input_price_per_1m,
      :market_output_price_per_1m,
      :context_window,
      :routing_strategy
    ])
    |> validate_required([
      :organization_id,
      :name,
      :display_name,
      :market_input_price_per_1m,
      :market_output_price_per_1m,
      :context_window,
      :routing_strategy
    ])
    |> validate_inclusion(:routing_strategy, @routing_strategies)
    |> unique_constraint(:name, name: :model_aliases_organization_id_name_index)
    |> foreign_key_constraint(:organization_id)
  end

  @doc "List of valid routing_strategy values"
  def routing_strategies, do: @routing_strategies
end
