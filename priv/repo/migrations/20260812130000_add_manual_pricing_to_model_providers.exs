defmodule Tokengate.Repo.Migrations.AddManualPricingToModelProviders do
  @moduledoc """
  Adds optional manual pricing (USD per 1M tokens) to model_providers.

  When the upstream doesn't report a cost (e.g. LiteLLM proxy in streaming
  mode), the cost calculator falls back to multiplying the actual token counts
  by these rates. NULL means "not set" — the request logs $0 when the upstream
  is also silent.

  Only meaningful for billing_mode = 'pay_per_token'. The UI only shows these
  fields when that mode is selected.
  """

  use Ecto.Migration

  def change do
    alter table(:model_providers) do
      add(:input_cost_per_million, :decimal, precision: 12, scale: 6, null: true)
      add(:output_cost_per_million, :decimal, precision: 12, scale: 6, null: true)
    end
  end
end
