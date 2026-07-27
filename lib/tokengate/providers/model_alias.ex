defmodule Tokengate.Providers.ModelAlias do
  @moduledoc """
  A model alias is a logical model name that maps to one or more
  provider-backed models (alias_providers).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "model_aliases" do
    field :name, :string
    field :display_name, :string
    field :market_input_price_per_1m, :decimal
    field :market_output_price_per_1m, :decimal
    field :context_window, :integer

    has_many :alias_providers, Tokengate.Providers.AliasProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model_alias, attrs) do
    model_alias
    |> cast(attrs, [
      :name,
      :display_name,
      :market_input_price_per_1m,
      :market_output_price_per_1m,
      :context_window
    ])
    |> validate_required([
      :name,
      :display_name,
      :market_input_price_per_1m,
      :market_output_price_per_1m,
      :context_window
    ])
    |> unique_constraint(:name)
  end
end
