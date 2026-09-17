defmodule Tokengate.Repo.Migrations.AddIconToModels do
  use Ecto.Migration

  def change do
    alter table(:models) do
      add :icon, :string
    end
  end
end
