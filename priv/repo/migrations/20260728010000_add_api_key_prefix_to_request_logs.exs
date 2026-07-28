defmodule Tokengate.Repo.Migrations.AddApiKeyPrefixToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :api_key_prefix, :string
    end
  end
end
