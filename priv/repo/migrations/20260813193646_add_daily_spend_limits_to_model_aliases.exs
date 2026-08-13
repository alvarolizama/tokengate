defmodule Tokengate.Repo.Migrations.AddDailySpendLimitsToModelAliases do
  @moduledoc """
  Adds two optional daily spending caps (USD) to model aliases.

    * `daily_limit_per_user_usd` — max daily spend for EACH individual user on
      this model. `NULL` (or 0) means unlimited.
    * `daily_limit_total_usd` — max total daily spend across ALL users on this
      model. `NULL` (or 0) means unlimited.

  Only `pay_per_token` providers consume these caps; `included` (subscription /
  RPM-limited) providers cost $0 and are never blocked by spending gates.
  """

  use Ecto.Migration

  def change do
    alter table(:model_aliases) do
      add(:daily_limit_per_user_usd, :decimal, precision: 12, scale: 6, null: true)
      add(:daily_limit_total_usd, :decimal, precision: 12, scale: 6, null: true)
    end
  end
end
