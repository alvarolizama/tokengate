defmodule Tokengate.Repo.Migrations.CreateRoutingRules do
  use Ecto.Migration

  def change do
    create table(:routing_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :name, :string, null: false
      add :conditions, :map, null: false, default: %{}
      add :target_alias_id, references(:model_aliases, type: :binary_id), null: false
      add :priority, :integer, null: false, default: 1
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:routing_rules, [:organization_id])
    create index(:routing_rules, [:target_alias_id])
  end
end
