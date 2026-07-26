defmodule Tokengate.Repo.Migrations.CreateProviders do
  use Ecto.Migration

  def change do
    create table(:providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :base_url, :string, null: false
      add :billing_type, :string, null: false, default: "pay_per_token"
      add :track_real_usage, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end
  end
end
