defmodule Tokengate.Repo.Migrations.AddCacheCostToModelProviders do
  @moduledoc """
  Adds cache_cost_per_million to model_providers for precise manual fallback.

  When the upstream doesn't report a cost, the cost calculator now uses three
  pricing fields: input (non-cached prompt), cache (cached prompt), and output
  (completion). All in USD per 1M tokens, nullable.
  """

  use Ecto.Migration

  def change do
    alter table(:model_providers) do
      add(:cache_cost_per_million, :decimal, precision: 12, scale: 6, null: true)
    end
  end
end
