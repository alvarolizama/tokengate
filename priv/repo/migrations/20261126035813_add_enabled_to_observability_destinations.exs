defmodule Tokengate.Repo.Migrations.AddEnabledToObservabilityDestinations do
  use Ecto.Migration

  def change do
    alter table(:observability_destinations) do
      add :enabled, :boolean, default: true, null: false
    end
  end
end
