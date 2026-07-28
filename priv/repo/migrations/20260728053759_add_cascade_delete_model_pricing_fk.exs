defmodule Tokengate.Repo.Migrations.AddCascadeDeleteModelPricingFk do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE model_pricing DROP CONSTRAINT IF EXISTS model_pricing_model_provider_id_fkey"

    alter table(:model_pricing) do
      modify :model_provider_id,
             references(:model_providers, type: :binary_id, on_delete: :delete_all),
             null: false
    end
  end

  def down do
    execute "ALTER TABLE model_pricing DROP CONSTRAINT IF EXISTS model_pricing_model_provider_id_fkey"

    alter table(:model_pricing) do
      modify :model_provider_id,
             references(:model_providers, type: :binary_id),
             null: false
    end
  end
end
