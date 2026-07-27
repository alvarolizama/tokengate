defmodule Tokengate.Repo.Migrations.AddNameToProviderCredentials do
  use Ecto.Migration

  def change do
    alter table(:provider_credentials) do
      add :name, :string
    end
  end
end
