defmodule Tokengate.Repo.Migrations.AddBillingModeToModelProviders do
  use Ecto.Migration

  def change do
    alter table(:model_providers) do
      add :billing_mode, :string, null: false, default: "pay_per_token"
    end
  end
end
