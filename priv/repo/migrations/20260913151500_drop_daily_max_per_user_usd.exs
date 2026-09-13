defmodule Tokengate.Repo.Migrations.DropDailyMaxPerUserUsd do
  use Ecto.Migration

  # Cap 2 (per-user daily cap) removed: the budget model is now 2 layers —
  # monthly per spending subject + the global daily kill-switch. The per-user
  # daily cap and its `user_daily` exemption scope are gone.
  def up do
    alter table(:global_settings) do
      remove :daily_max_per_user_usd
    end
  end

  def down do
    alter table(:global_settings) do
      add :daily_max_per_user_usd, :numeric, precision: 12, scale: 2
    end
  end
end
