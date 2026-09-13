defmodule Tokengate.Repo.Migrations.DropModelDailyLimitPerUserUsd do
  use Ecto.Migration

  # Cap 5 (per-model per-user daily cap) removed completely — code and column.
  def up do
    alter table(:models) do
      remove :daily_limit_per_user_usd
    end
  end

  def down do
    alter table(:models) do
      add :daily_limit_per_user_usd, :numeric, precision: 12, scale: 6
    end
  end
end
