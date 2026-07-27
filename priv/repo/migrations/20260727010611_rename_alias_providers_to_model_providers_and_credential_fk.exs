defmodule Tokengate.Repo.Migrations.RenameAliasProvidersToModelProvidersAndCredentialFk do
  use Ecto.Migration

  @table_exists "SELECT to_regclass('alias_providers')"
  @col_exists "SELECT column_name FROM information_schema.columns WHERE table_name='model_providers' AND column_name='credential_id'"

  def up do
    # Rename table (only if old name exists)
    if row_exists(@table_exists) do
      rename table(:alias_providers), to: table(:model_providers)
    end

    # Add credential_id column if not present
    unless row_exists(@col_exists) do
      alter table(:model_providers) do
        add :credential_id, references(:provider_credentials, type: :binary_id)
      end

      # Backfill credential_id from provider_id: pick the first active credential
      execute """
      UPDATE model_providers mp
      SET credential_id = (
        SELECT c.id FROM provider_credentials c
        WHERE c.provider_id = mp.provider_id
          AND c.status = 'active'
        ORDER BY c.inserted_at ASC
        LIMIT 1
      )
      """

      # Drop old provider_id FK column
      alter table(:model_providers) do
        remove :provider_id
      end

      # Make credential_id NOT NULL
      alter table(:model_providers) do
        modify :credential_id, :binary_id, null: false
      end
    end

    # Rename indexes (table rename doesn't auto-rename indexes)
    execute "ALTER INDEX IF EXISTS alias_providers_model_alias_id_index RENAME TO model_providers_model_alias_id_index"

    execute "ALTER INDEX IF EXISTS alias_providers_provider_id_index RENAME TO model_providers_credential_id_index"
  end

  def down do
    rename table(:model_providers), to: table(:alias_providers)

    alter table(:alias_providers) do
      add :provider_id, references(:providers, type: :binary_id)
    end

    execute """
    UPDATE alias_providers ap
    SET provider_id = (
      SELECT c.provider_id FROM provider_credentials c
      WHERE c.id = ap.credential_id
    )
    """

    alter table(:alias_providers) do
      remove :credential_id
    end

    execute "ALTER INDEX IF EXISTS model_providers_model_alias_id_index RENAME TO alias_providers_model_alias_id_index"

    execute "ALTER INDEX IF EXISTS model_providers_credential_id_index RENAME TO alias_providers_provider_id_index"
  end

  defp row_exists(sql) do
    %{rows: rows} = Ecto.Migration.repo().query!(sql)
    rows != [] and hd(hd(rows)) != nil
  end
end
