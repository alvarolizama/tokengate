defmodule Tokengate.Repo.Migrations.AddErrorMessageToCredentials do
  use Ecto.Migration

  def change do
    alter table(:provider_credentials) do
      add :error_message, :string
    end
  end
end
