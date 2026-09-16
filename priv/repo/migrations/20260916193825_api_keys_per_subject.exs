defmodule Tokengate.Repo.Migrations.ApiKeysPerSubject do
  use Ecto.Migration

  # Las API keys pasan a colgar del usuario (no de la membresía de grupo) y a ser
  # múltiples con label: N keys activas por sujeto. La key es del usuario, no de
  # la membresía; `group_member_id` se conserva para la resolución del plug pero
  # deja de ser único por sujeto.
  def up do
    alter table(:api_keys) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :label, :string
    end

    # Backfill: el dueño de una key "member" es el usuario del group_member.
    execute(
      "UPDATE api_keys k SET user_id = gm.user_id FROM group_members gm " <>
        "WHERE k.subject_type = 'member' AND k.group_member_id = gm.id AND k.user_id IS NULL"
    )

    # Se eliminan los índices únicos parciales que limitaban a 1 key activa por
    # sujeto; `api_keys_key_hash_index` (global) se conserva.
    drop_if_exists(
      index(:api_keys, [:group_member_id], name: :api_keys_group_member_active_index)
    )

    drop_if_exists(index(:api_keys, [:service_id], name: :api_keys_service_id_active_index))
  end

  def down do
    # Restauramos la restricción de 1 key activa por sujeto.
    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS api_keys_group_member_active_index " <>
        "ON api_keys (group_member_id) " <>
        "WHERE subject_type = 'member' AND status = 'active'"
    )

    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS api_keys_service_id_active_index " <>
        "ON api_keys (service_id) " <>
        "WHERE subject_type = 'service' AND status = 'active'"
    )

    alter table(:api_keys) do
      remove :user_id
      remove :label
    end
  end
end
