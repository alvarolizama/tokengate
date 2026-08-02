defmodule Tokengate.Providers.ModelAlias do
  @moduledoc """
  A model alias is a logical model name that maps to one or more
  provider-backed models (model_providers).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "model_aliases" do
    field :name, :string
    field :display_name, :string
    field :description, :string
    field :context_window, :integer
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
      :guard_rails,
      :prompt_cache_enabled,
      :lazy_cleanup_enabled
    ])
    |> validate_required([:name, :display_name, :context_window])
    |> unique_constraint(:name)
  end
end
