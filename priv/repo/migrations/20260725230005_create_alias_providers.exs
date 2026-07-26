defmodule Tokengate.Repo.Migrations.CreateAliasProviders do
  use Ecto.Migration

  def change do
    create table(:alias_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :model_alias_id, references(:model_aliases, type: :binary_id), null: false
      add :provider_id, references(:providers, type: :binary_id), null: false
      add :provider_model, :string, null: false
      add :subscription_id, references(:provider_subscriptions, type: :binary_id)
      add :priority, :integer
      add :weight, :integer
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:alias_providers, [:model_alias_id])
    create index(:alias_providers, [:provider_id])
    create index(:alias_providers, [:subscription_id])
  end
end
