defmodule Tokengate.Repo.Migrations.AddDailyMaxPerUserToGlobalSettings do
  use Ecto.Migration

  def change do
    alter table(:global_settings) do
      add :daily_max_per_user_usd, :decimal, precision: 12, scale: 2
    end
  end
end
