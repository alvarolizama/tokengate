defmodule Tokengate.Repo.Migrations.CreateModelAliases do
  use Ecto.Migration

  def change do
    create table(:model_aliases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :name, :string, null: false
      add :display_name, :string, null: false
      add :market_input_price_per_1m, :decimal, null: false
      add :market_output_price_per_1m, :decimal, null: false
      add :context_window, :integer, null: false
      add :routing_strategy, :string, null: false, default: "priority"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:model_aliases, [:organization_id, :name])
  end
end
