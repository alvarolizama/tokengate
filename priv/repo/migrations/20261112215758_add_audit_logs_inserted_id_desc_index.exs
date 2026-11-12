defmodule Tokengate.Repo.Migrations.AddAuditLogsInsertedIdDescIndex do
  @moduledoc """
  `Auditing.list_audit_logs/1` ordena `inserted_at DESC, id DESC` con OFFSET
  sobre `audit_logs` (particionada por mes). El único índice que cubría el
  orden era `audit_logs_inserted_at_index (inserted_at)`: sin el tiebreaker
  `id`, Postgres no puede satisfacer el orden completo desde el índice y cae
  a un sort (o al scan de la partición entera) en cuanto el listado pagina.

  `(inserted_at DESC, id DESC)` sirve además los rangos de `inserted_at` del
  filtro y del `count`, así que reemplaza al índice viejo: mantener ambos
  duplicaría la amplificación de escritura en la ruta de auditoría, que es
  caliente.

  Índice sobre la tabla PADRE: se propaga a cada partición, y las mensuales
  nuevas (creadas por `Auditing.PartitionWorker`) lo heredan.
  """

  use Ecto.Migration

  def up do
    execute "DROP INDEX IF EXISTS audit_logs_inserted_at_index"

    execute "CREATE INDEX audit_logs_inserted_id_desc_idx ON audit_logs (inserted_at DESC, id DESC)"
  end

  def down do
    execute "DROP INDEX IF EXISTS audit_logs_inserted_id_desc_idx"
    execute "CREATE INDEX IF NOT EXISTS audit_logs_inserted_at_index ON audit_logs (inserted_at)"
  end
end
