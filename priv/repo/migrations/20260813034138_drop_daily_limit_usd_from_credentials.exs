defmodule Tokengate.Repo.Migrations.DropDailyLimitUsdFromCredentials do
  use Ecto.Migration

  def change do
    alter table(:provider_credentials) do
      remove(:daily_limit_usd)
    end
  end
end
