defmodule Tokengate.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_member_id, references(:team_members, type: :binary_id), null: false
      add :key_hash, :string, null: false
      add :key_prefix, :string, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    # One api key row per team_member (revocation replaces the key material
    # in place via replace_api_key/1, preserving the unique constraint).
    create unique_index(:api_keys, [:team_member_id])
    create unique_index(:api_keys, [:key_hash])
  end
end
