defmodule Tokengate.Providers.Model do
  @moduledoc """
  A model model is a logical model name that maps to one or more
  provider-backed models (model_providers).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @model_types ~w(llm embedding)

  schema "models" do
    field :name, :string
    field :context_window, :integer
    field :model_type, :string, default: "llm"
    field :guard_rails, :string
    field :prompt_cache_enabled, :boolean, default: false
    field :lazy_cleanup_enabled, :boolean, default: false
    field :pinned, :boolean, default: false
    # The models.dev id this row was created from (nil = built by hand in the
    # admin form). Kept independently of `name`, which the operator may shorten:
    # the link is what lets the picker say "ya existe" and what a future
    # re-sync of the catalog metadata hangs off.
    field :catalog_model_key, :string
    # The lab that built the model, from the catalog id's prefix (soft link to
    # `labs.key`: a lab row is not required for the model to exist).
    field :lab_key, :string
    # Informational market prices (USD per 1M tokens). Display-only:
    # the billing chain (CostCalculator / manual_pricing / backfill) never
    # reads these — it uses provider-reported costs plus the per-provider
    # manual fallback on model_providers. Prefilled from the catalog when the
    # model is created from it.
    field :market_input_price_per_1m, :decimal
    field :market_output_price_per_1m, :decimal
    field :market_cache_price_per_1m, :decimal

    has_many :model_providers, Tokengate.Providers.ModelProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :name,
      :context_window,
      :model_type,
      :guard_rails,
      :prompt_cache_enabled,
      :lazy_cleanup_enabled,
      :pinned,
      :catalog_model_key,
      :lab_key,
      :market_input_price_per_1m,
      :market_output_price_per_1m,
      :market_cache_price_per_1m
    ])
    |> validate_required([:name, :context_window])
    |> validate_inclusion(:model_type, @model_types)
    |> unique_constraint(:name)
  end

  @doc "List of valid model types"
  def model_types, do: @model_types
end
