defmodule Tokengate.Repo.Migrations.AddCredentialErrorFields do
  use Ecto.Migration

  def up do
    alter table(:provider_credentials) do
      add :error_reason, :string
      add :error_at, :utc_datetime
    end

    # Allow "error" as a valid status alongside "active" and "disabled".
    execute "ALTER TABLE provider_credentials DROP CONSTRAINT IF EXISTS provider_credentials_status_check"

    execute """
    ALTER TABLE provider_credentials
    ADD CONSTRAINT provider_credentials_status_check
    CHECK (status IN ('active', 'disabled', 'error'))
    """
  end

  def down do
    alter table(:provider_credentials) do
      remove :error_reason
      remove :error_at
    end

    execute "ALTER TABLE provider_credentials DROP CONSTRAINT IF EXISTS provider_credentials_status_check"

    execute """
    ALTER TABLE provider_credentials
    ADD CONSTRAINT provider_credentials_status_check
    CHECK (status IN ('active', 'disabled'))
    """
  end
end
