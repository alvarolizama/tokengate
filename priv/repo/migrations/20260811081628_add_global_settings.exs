defmodule Tokengate.Repo.Migrations.AddGlobalSettings do
  use Ecto.Migration

  def change do
    create table(:global_settings, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1
      add :daily_max_spend_usd, :decimal, null: true

      timestamps(type: :utc_datetime)
    end

    execute(
      "INSERT INTO global_settings (id, daily_max_spend_usd, inserted_at, updated_at) VALUES (1, NULL, NOW(), NOW())",
      "DELETE FROM global_settings WHERE id = 1"
    )
  end
end
