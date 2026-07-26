defmodule Tokengate.Repo.Migrations.CreateObservabilityDestinations do
  use Ecto.Migration

  def change do
    create table(:observability_destinations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :name, :string
      add :type, :string, default: "otlp_webhook"
      add :url, :string
      add :headers, :map, default: %{}
      add :privacy_mode, :string, default: "metadata_only"

      timestamps(type: :utc_datetime)
    end

    create index(:observability_destinations, [:organization_id])
  end
end
