defmodule Tokengate.Repo.Migrations.AddApiKeyIdToRequestLogs do
  @moduledoc """
  Añade `request_logs.api_key_id` (y su índice) para poder agregar el consumo
  **por key**, no solo por prefijo.

  El histórico no se backfillea: las filas viejas quedan con `api_key_id` NULL
  y `api_key_prefix` sigue siendo el puente para agruparlas (una key revocada y
  recreada comparte prefijo, así que el prefijo nunca fue suficiente).

  `request_logs` es una tabla particionada nativa por RANGE: los ALTER sobre la
  tabla padre cascadean a todas las particiones (existentes y futuras), y los
  índices se crean **en el padre con SQL crudo** — Postgres los propaga solo,
  igual que en `20260808055508_add_missing_indexes_to_request_logs`.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:request_logs) do
      add :api_key_id, :binary_id
    end

    # Índice compuesto (key, tiempo) en el PADRE: es el patrón de consulta del
    # consumo por key (WHERE api_key_id = ? AND inserted_at >= ?).
    execute """
    CREATE INDEX IF NOT EXISTS request_logs_api_key_inserted_idx
      ON request_logs (api_key_id, inserted_at)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_api_key_inserted_idx"

    alter table(:request_logs) do
      remove :api_key_id
    end
  end
end
