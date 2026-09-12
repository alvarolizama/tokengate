defmodule Tokengate.Repo.Migrations.UnifyApiKeysAndGroupMembership do
  use Ecto.Migration

  def up do
    # 1. api_keys pasa a ser polimórfica: subject_type ("member" | "service")
    #    + group_member_id nullable + service_id.
    alter table(:api_keys) do
      add :subject_type, :string, null: false, default: "member"
      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all)
      modify :group_member_id, :binary_id, null: true
    end

    # Migrar las service_api_keys existentes a la tabla unificada.
    execute """
            INSERT INTO api_keys (id, subject_type, service_id, key_hash, key_prefix, status, inserted_at, updated_at)
            SELECT id, 'service', service_id, key_hash, key_prefix, status, inserted_at, updated_at
            FROM service_api_keys
            ON CONFLICT (key_hash) DO NOTHING
            """,
            ""

    # Una key activa por subject: índices parciales únicos.
    execute "DROP INDEX IF EXISTS api_keys_group_member_id_index",
            "CREATE UNIQUE INDEX api_keys_group_member_id_index ON api_keys (group_member_id)"

    execute """
            CREATE UNIQUE INDEX api_keys_group_member_active_index
            ON api_keys (group_member_id)
            WHERE subject_type = 'member' AND status = 'active'
            """,
            "DROP INDEX IF EXISTS api_keys_group_member_active_index"

    execute """
            CREATE UNIQUE INDEX api_keys_service_id_active_index
            ON api_keys (service_id)
            WHERE subject_type = 'service' AND status = 'active'
            """,
            "DROP INDEX IF EXISTS api_keys_service_id_active_index"

    drop table(:service_api_keys)

    # 2. Todo servicio pertenece obligatoriamente a un grupo.
    alter table(:services) do
      add :group_id, references(:groups, type: :binary_id, on_delete: :restrict)
    end

    execute """
            INSERT INTO groups (id, name, inserted_at, updated_at)
            SELECT gen_random_uuid(), 'Servicios', now(), now()
            WHERE NOT EXISTS (SELECT 1 FROM groups WHERE name = 'Servicios')
            """,
            ""

    execute """
            UPDATE services
            SET group_id = (SELECT id FROM groups WHERE name = 'Servicios' LIMIT 1)
            WHERE group_id IS NULL
            """,
            ""

    alter table(:services) do
      modify :group_id, :binary_id, null: false
    end

    # 3. Eliminar group_role (rol solo a nivel plataforma: global_role).
    alter table(:group_members) do
      remove :group_role
    end

    # 4. Exclusividad de provider por servicio.
    alter table(:model_providers) do
      add :exclusive_to_service_id,
          references(:services, type: :binary_id, on_delete: :delete_all)
    end

    execute """
            CREATE UNIQUE INDEX model_providers_service_exclusive_credential_unique_index
            ON model_providers (credential_id, model_id, exclusive_to_service_id)
            WHERE exclusive_to_service_id IS NOT NULL
            """,
            "DROP INDEX IF EXISTS model_providers_service_exclusive_credential_unique_index"
  end

  def down do
    alter table(:model_providers) do
      remove :exclusive_to_service_id
    end

    alter table(:group_members) do
      add :group_role, :string, null: false, default: "user"
    end

    alter table(:services) do
      modify :group_id, :binary_id, null: true
    end

    alter table(:api_keys) do
      remove :service_id
      remove :subject_type
      modify :group_member_id, :binary_id, null: false
    end

    execute "CREATE TABLE IF NOT EXISTS service_api_keys (LIKE api_keys INCLUDING DEFAULTS)",
            ""

    execute """
            INSERT INTO service_api_keys (id, service_id, key_hash, key_prefix, status, inserted_at, updated_at)
            SELECT id, service_id, key_hash, key_prefix, status, inserted_at, updated_at
            FROM api_keys WHERE subject_type = 'service'
            """,
            ""

    execute "DROP INDEX IF EXISTS api_keys_service_id_active_index", ""

    execute """
            CREATE UNIQUE INDEX api_keys_group_member_id_index
            ON api_keys (group_member_id)
            """,
            ""
  end
end
