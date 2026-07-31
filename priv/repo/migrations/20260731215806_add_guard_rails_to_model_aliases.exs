defmodule Tokengate.Repo.Migrations.AddGuardRailsToModelAliases do
  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      add :guard_rails, :text
    end
  end
end
