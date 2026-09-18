defmodule Tokengate.Repo.Migrations.AuditLogsPartitionedAndContext do
  @moduledoc """
  Convierte `audit_logs` en tabla Postgres RANGE-particionada por
  `inserted_at` (particiones **mensuales**, gestionadas por
  `Tokengate.Auditing.PartitionWorker`), añade el contexto de auditoría
  (actor desnormalizado, "actuando como", IP, user-agent, origin, target_label)
  y la vuelve **append-only real** con un trigger que rechaza `UPDATE`/`DELETE`.

  El histórico se conserva: se copia a la tabla nueva antes de sustituirla.
  `id` deja de ser PK simple y pasa a ser PK compuesta `(id, inserted_at)`,
  requisito de Postgres en tablas particionadas.
  """

  use Ecto.Migration

  def up do
    # 1. Tabla particionada nueva con todas las columnas.
    execute """
    CREATE TABLE audit_logs_parted (
      id uuid NOT NULL,
      user_id uuid,
      actor_email varchar(255),
      actor_role varchar(255),
      acting_as_id uuid,
      acting_as_email varchar(255),
      action varchar(255),
      entity_type varchar(255),
      entity_id varchar(255),
      target_label varchar(255),
      origin varchar(255) DEFAULT 'web',
      ip varchar(255),
      user_agent text,
      changes jsonb DEFAULT '{}'::jsonb,
      inserted_at timestamp(0) without time zone NOT NULL,
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """

    # La partición default captura cualquier mes sin partición propia; el
    # worker crea las mensuales hacia adelante y mueve lo rezagado.
    execute "CREATE TABLE audit_logs_default PARTITION OF audit_logs_parted DEFAULT"

    # 2. Copia del histórico.
    execute """
    INSERT INTO audit_logs_parted
      (id, user_id, action, entity_type, entity_id, changes, inserted_at)
    SELECT id, user_id, action, entity_type, entity_id, changes, inserted_at
    FROM audit_logs
    """

    # 3. Sustitución.
    execute "DROP TABLE audit_logs"
    execute "ALTER TABLE audit_logs_parted RENAME TO audit_logs"

    # 4. FK a users (SET NULL: se conserva el rastro, se pierde la atribución
    #    por join — por eso el actor_email desnormalizado).
    execute """
    ALTER TABLE audit_logs
      ADD CONSTRAINT audit_logs_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
    """

    # 5. Índices (se replican a cada partición).
    execute "CREATE INDEX audit_logs_inserted_at_index ON audit_logs (inserted_at)"
    execute "CREATE INDEX audit_logs_user_id_index ON audit_logs (user_id)"
    execute "CREATE INDEX audit_logs_entity_index ON audit_logs (entity_type, entity_id)"
    execute "CREATE INDEX audit_logs_action_index ON audit_logs (action)"
    execute "CREATE INDEX audit_logs_actor_email_index ON audit_logs (actor_email)"

    # 6. Append-only real.
    execute """
    CREATE OR REPLACE FUNCTION audit_logs_append_only() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'audit_logs is append-only (op: %)', TG_OP;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER audit_logs_append_only_trigger
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION audit_logs_append_only()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS audit_logs_append_only_trigger ON audit_logs"
    execute "DROP FUNCTION IF EXISTS audit_logs_append_only()"

    execute "ALTER TABLE audit_logs RENAME TO audit_logs_parted"

    execute """
    CREATE TABLE audit_logs (
      id uuid NOT NULL PRIMARY KEY,
      user_id uuid,
      action varchar(255),
      entity_type varchar(255),
      entity_id varchar(255),
      changes jsonb DEFAULT '{}'::jsonb,
      inserted_at timestamp(0) without time zone NOT NULL
    )
    """

    execute """
    INSERT INTO audit_logs (id, user_id, action, entity_type, entity_id, changes, inserted_at)
    SELECT id, user_id, action, entity_type, entity_id, changes, inserted_at
    FROM audit_logs_parted
    """

    execute "DROP TABLE audit_logs_parted"

    execute """
    ALTER TABLE audit_logs
      ADD CONSTRAINT audit_logs_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
    """

    execute "CREATE INDEX audit_logs_user_id_index ON audit_logs (user_id)"
    execute "CREATE INDEX audit_logs_entity_index ON audit_logs (entity_type, entity_id)"
    execute "CREATE INDEX audit_logs_inserted_at_index ON audit_logs (inserted_at)"
  end
end
