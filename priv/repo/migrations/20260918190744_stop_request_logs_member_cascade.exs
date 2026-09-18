defmodule Tokengate.Repo.Migrations.StopRequestLogsMemberCascade do
  @moduledoc """
  Cambia la FK `request_logs.group_member_id` de `ON DELETE CASCADE` a
  `ON DELETE SET NULL`.

  El CASCADE borra el histórico de gasto del usuario cuando su membresía se
  rota (cambio de grupo/sub) o se purga por duplicado
  (`20260917011526_one_monthly_sub_per_user` borra membresías y arrastra sus
  request_logs). El saldo que el motor de créditos ya había debitado sigue
  agotado — su evidencia durable desaparece: ni el dashboard ni los propios
  `Credits.spend_by_subjects/2` (que leen request_logs por `user_id`) pueden
  volver a cuadrar con el enforcement.

  La identidad durable del gasto ya viaja en la fila (`request_logs.user_id`,
  `20260917033650`): al rotar la membresía basta con soltar el puntero
  (`group_member_id → NULL`); la atribución por usuario sobrevive.

  ## Particiones: por qué la FK va SIN `NOT VALID`

  `request_logs` es RANGE-particionada por `inserted_at`. La variante barata
  `ADD CONSTRAINT ... NOT VALID` (marca el check para filas nuevas y difiere la
  validación) **no existe para tablas particionadas en Postgres < 18**:

      42809 (wrong_object_type) cannot add NOT VALID foreign key on partitioned
      table "request_logs" referencing relation "group_members"

  AlloyDB (producción) va sobre el linaje 15/16 y la rechaza, aunque en el dev
  local (PG 18, donde la restricción ya se levantó) pase — de ahí que la
  versión original de esta migración funcionara en dev y rompiera el deploy.
  Se usa entonces la variante **validada**: Postgres la acepta en el padre
  particionado, la propaga a todas las particiones (existentes y futuras) y
  valida las filas presentes de una vez — `VALIDATE CONSTRAINT` ya no hace falta.

  Coste medido (PG 16.15, 4M de filas): ~0.2 s de validación. El ALTER toma
  `SHARE ROW EXCLUSIVE` sobre el padre: **los SELECT siguen fluyendo** y sólo
  pausan los INSERT/UPDATE/DELETE de `request_logs` durante ese ratón. Cada
  bloque corre con `SET LOCAL lock_timeout = '3s'` (patrón de
  `20260901161239_drop_request_logs_set_null_fks`): si el ALTER topa con una
  query larga falla rápido y se re-corre en un momento tranquilo — todo es
  idempotente (`IF EXISTS`, y `DROP` antes del `ADD`).

  Si al validar quedan punteros colgantes (filas con un `group_member_id` sin
  membresía, insertadas mientras la FK estuvo ausente por el deploy fallido del
  2026-09-18), el `ADD` falla con 23503: el bloque las limpia a `NULL` y
  reintenta. Un huérfano no tiene membresía que preservar, y el CASCADE que se
  está retirando ya las habría borrado.

  ## Borrados acotados

  `request_logs_member_inserted_covering_idx (group_member_id, inserted_at)`
  (`20260827054110`) está en el padre y en cada partición — se creó justo para
  esto: el barrido de mantenimiento de la FK se resuelve por índice en vez de
  recorrer la partición entera. Por eso no hace falta un índice nuevo (ni su
  coste de escritura en el camino del proxy).

  ## down

  Re-agrega la FK CASCADE **sin `NOT VALID`** por la misma razón. Mientras esta
  migración estuvo aplicada la FK estuvo viva, así que no debería haber ids
  colgantes que hagan fallar la validación; si los hubiera por cualquier otra
  vía, el bloque los limpia igual que en `up/0`.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @constraint "request_logs_group_member_id_fkey"
  @fk "FOREIGN KEY (group_member_id) REFERENCES group_members(id)"

  def up do
    execute drop_constraint()
    execute add_constraint("ON DELETE SET NULL")
  end

  def down do
    execute drop_constraint()
    execute add_constraint("ON DELETE CASCADE")
  end

  defp drop_constraint do
    """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';
      ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS #{@constraint};
    END
    $$;
    """
  end

  defp add_constraint(action) do
    """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';

      BEGIN
        ALTER TABLE request_logs ADD CONSTRAINT #{@constraint}
          #{@fk}
          #{action};
      EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'request_logs: group_member_id colgantes, se limpian a NULL y se reintenta';
        UPDATE request_logs SET group_member_id = NULL
         WHERE group_member_id IS NOT NULL
           AND NOT EXISTS (
             SELECT 1 FROM group_members gm WHERE gm.id = request_logs.group_member_id
           );

        ALTER TABLE request_logs ADD CONSTRAINT #{@constraint}
          #{@fk}
          #{action};
      END;
    END
    $$;
    """
  end
end
