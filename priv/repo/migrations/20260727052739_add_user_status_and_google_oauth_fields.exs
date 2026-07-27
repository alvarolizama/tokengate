defmodule Tokengate.Repo.Migrations.AddUserStatusAndGoogleOauthFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :status, :string, default: "active", null: false
      add :google_id, :string
      add :avatar_url, :string
    end

    create unique_index(:users, [:google_id])
  end
end
