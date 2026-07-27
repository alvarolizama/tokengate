defmodule Tokengate.Repo.Migrations.RemoveRoutingRules do
  use Ecto.Migration

  def up do
    drop_if_exists table(:routing_rules)
  end

  def down do
    create table(:routing_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :conditions, :map, null: false, default: %{}
      add :priority, :integer, default: 1
      add :enabled, :boolean, default: true
      add :target_alias_id, references(:model_aliases, type: :binary_id), null: false
      timestamps(type: :utc_datetime)
    end

    create index(:routing_rules, [:target_alias_id])
  end
end
