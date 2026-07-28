defmodule Tokengate.Repo.Migrations.AddReceiveTimeoutToCredentials do
  use Ecto.Migration

  def change do
    alter table(:provider_credentials) do
      add :receive_timeout_ms, :integer, default: 120_000, null: false
    end
  end
end
