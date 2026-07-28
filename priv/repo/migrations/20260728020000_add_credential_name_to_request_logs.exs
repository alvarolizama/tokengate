defmodule Tokengate.Repo.Migrations.AddCredentialNameToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :credential_name, :string
    end
  end
end
