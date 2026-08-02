defmodule Tokengate.Repo.Migrations.AddDescriptionToModelAliases do
  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      add :description, :string
    end
  end
end
