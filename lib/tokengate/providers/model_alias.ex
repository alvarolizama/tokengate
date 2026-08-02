defmodule Tokengate.Providers.ModelAlias do
  @moduledoc """
  A model alias is a logical model name that maps to one or more
  provider-backed models (model_providers).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @model_types ~w(llm embedding rerank)

  schema "model_aliases" do
    field :name, :string
    field :display_name, :string
    field :description, :string
    field :context_window, :integer
    field :model_type, :string, default: "llm"
    field :guard_rails, :string
    field :prompt_cache_enabled, :boolean, default: false
    field :lazy_cleanup_enabled, :boolean, default: false

    has_many :model_providers, Tokengate.Providers.ModelProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model_alias, attrs) do
    model_alias
    |> cast(attrs, [
      :name,
      :display_name,
      :description,
      :context_window,
      :model_type,
      :guard_rails,
      :prompt_cache_enabled,
      :lazy_cleanup_enabled
    ])
    |> validate_required([:name, :display_name, :context_window])
    |> validate_inclusion(:model_type, @model_types)
    |> unique_constraint(:name)
  end

  @doc "List of valid model types"
  def model_types, do: @model_types
end
