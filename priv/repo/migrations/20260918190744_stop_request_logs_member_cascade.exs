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

  ## Particiones

  `request_logs` es RANGE-particionada por `inserted_at`: el ALTER sobre el
  padre cascadea a todas las particiones (existentes y futuras). La FK
  re-agregada queda `NOT VALID` y se valida con `VALIDATE CONSTRAINT` — en el
  padre particionado la validación recorre las particiones SIN tomar ACCESS
  EXCLUSIVE (SHARE UPDATE EXCLUSIVE), y como `group_member_id` sólo apunta a
  membresías vivas en las filas presentes, la validación pasa.

  Cada bloque corre con `SET LOCAL lock_timeout` (patrón de
  `20260901161239_drop_request_logs_set_null_fks`): si el ALTER topa con una
  query larga, falla rápido y se re-corre en un momento tranquilo — todo es
  idempotente (`IF EXISTS`).

  ## down

  Re-agrega la FK CASCADE original `NOT VALID`: una vez rotado, las filas
  viejas tienen `group_member_id` colgante y una validación completa
  fallaría con 23503. `NOT VALID` mantiene el check para filas nuevas.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';
      ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_group_member_id_fkey;
    END
    $$;
    """

    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';
      ALTER TABLE request_logs ADD CONSTRAINT request_logs_group_member_id_fkey
        FOREIGN KEY (group_member_id) REFERENCES group_members(id)
        ON DELETE SET NULL NOT VALID;
    END
    $$;
    """

    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '10s';
      ALTER TABLE request_logs VALIDATE CONSTRAINT request_logs_group_member_id_fkey;
    END
    $$;
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';
      ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_group_member_id_fkey;
    END
    $$;
    """

    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '3s';
      ALTER TABLE request_logs ADD CONSTRAINT request_logs_group_member_id_fkey
        FOREIGN KEY (group_member_id) REFERENCES group_members(id)
        ON DELETE CASCADE NOT VALID;
    END
    $$;
    """
  end
end
