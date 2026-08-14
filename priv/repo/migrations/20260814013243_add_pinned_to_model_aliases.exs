defmodule Tokengate.Repo.Migrations.AddPinnedToModelAliases do
  @moduledoc """
  Adds a `pinned` flag to model aliases so admins can pin models to the top
  of the /dashboard/models list.
  """

  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      add :pinned, :boolean, null: false, default: false
    end
  end
end
