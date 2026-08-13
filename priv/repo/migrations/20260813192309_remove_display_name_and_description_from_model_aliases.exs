defmodule Tokengate.Repo.Migrations.RemoveDisplayNameAndDescriptionFromModelAliases do
  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      remove :display_name
      remove :description
    end
  end
end
