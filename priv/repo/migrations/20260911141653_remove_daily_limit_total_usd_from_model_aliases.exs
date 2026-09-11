defmodule Tokengate.Repo.Migrations.RemoveDailyLimitTotalUsdFromModelAliases do
  @moduledoc """
  Drops `model_aliases.daily_limit_total_usd` — the model-wide total daily
  cap was removed from the product. The per-user cap
  (`daily_limit_per_user_usd`) stays.
  """

  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      remove(:daily_limit_total_usd, :decimal, precision: 12, scale: 6, null: true)
    end
  end
end
