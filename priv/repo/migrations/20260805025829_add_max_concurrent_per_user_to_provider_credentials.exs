defmodule Tokengate.Repo.Migrations.AddMaxConcurrentPerUserToProviderCredentials do
  use Ecto.Migration

  def change do
    alter table(:provider_credentials) do
      add(:max_concurrent_per_user, :integer, null: true)
    end
  end
end
