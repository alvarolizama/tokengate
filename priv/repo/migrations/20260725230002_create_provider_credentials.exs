defmodule Tokengate.Repo.Migrations.CreateProviderCredentials do
  use Ecto.Migration

  def change do
    create table(:provider_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_id, references(:providers, type: :binary_id), null: false
      add :api_key_encrypted, :string, null: false
      add :max_rpm, :integer
      add :max_concurrent, :integer
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:provider_credentials, [:provider_id])
  end
end
