defmodule Tokengate.Repo.Migrations.AddProviderStatusAndErrorToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :provider_status_code, :integer
      add :error_reason, :string
    end
  end
end
