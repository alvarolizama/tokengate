defmodule Tokengate.Repo.Migrations.RemoveOrganizations do
  use Ecto.Migration

  def up do
    # Drop FK constraints and organization_id columns
    alter table(:teams) do
      remove :organization_id
    end

    alter table(:model_aliases) do
      remove :organization_id
    end

    # model_aliases unique index was [:organization_id, :name] — replace with just :name
    drop_if_exists index(:model_aliases, [:organization_id, :name])
    create unique_index(:model_aliases, [:name])

    alter table(:routing_rules) do
      remove :organization_id
    end

    drop_if_exists index(:routing_rules, [:organization_id])

    alter table(:observability_destinations) do
      remove :organization_id
    end

    drop_if_exists index(:observability_destinations, [:organization_id])

    drop_if_exists table(:organizations)
  end

  def down do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :cost_tracking_mode, :string, default: "value"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])

    alter table(:teams) do
      add :organization_id, references(:organizations, type: :binary_id), null: false
    end

    create index(:teams, [:organization_id])

    alter table(:model_aliases) do
      add :organization_id, references(:organizations, type: :binary_id), null: false
    end

    drop_if_exists unique_index(:model_aliases, [:name])
    create unique_index(:model_aliases, [:organization_id, :name])

    alter table(:routing_rules) do
      add :organization_id, references(:organizations, type: :binary_id), null: false
    end

    create index(:routing_rules, [:organization_id])

    alter table(:observability_destinations) do
      add :organization_id, references(:organizations, type: :binary_id), null: false
    end

    create index(:observability_destinations, [:organization_id])
  end
end
