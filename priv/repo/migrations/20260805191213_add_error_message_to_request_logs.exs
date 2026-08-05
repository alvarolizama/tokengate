defmodule Tokengate.Repo.Migrations.AddErrorMessageToRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:request_logs) do
      add :error_message, :string
    end
  end
end
