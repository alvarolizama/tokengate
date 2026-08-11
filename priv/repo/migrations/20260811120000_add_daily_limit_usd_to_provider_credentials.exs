defmodule Tokengate.Repo.Migrations.AddDailyLimitUsdToProviderCredentials do
  @moduledoc """
  Adds an optional daily spending cap (USD) to provider credentials.

  When set, the proxy tracks the credential's accumulated `provider_cost_usd`
  per UTC day and excludes it from routing once the cap is reached, failing
  over to the next credential in priority. `NULL` means unlimited.
  """

  use Ecto.Migration

  def change do
    alter table(:provider_credentials) do
      add(:daily_limit_usd, :decimal, precision: 12, scale: 6, null: true)
    end
  end
end
