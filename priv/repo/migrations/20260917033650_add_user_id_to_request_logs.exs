defmodule Tokengate.Repo.Migrations.AddUserIdToRequestLogs do
  @moduledoc """
  Añade `request_logs.user_id`: la columna que iguala usuario y servicio en la
  tabla de verdad.

  Antes, agregar el gasto **por usuario** exigía un `join` a `group_members`
  (`credits.ex`, `spend_grouped_users/2`) mientras el servicio leía su columna
  directa (`service_id`). La asimetría era profunda además de costosa: cambiar de
  sub borra las membresías viejas en cascada
  (`20260917011526_one_monthly_sub_per_user`), así que el gasto del usuario
  dependía de una fila que puede desaparecer. Con `user_id` el sujeto del gasto
  viaja en la fila.

  ## Particiones

  `request_logs` es una tabla particionada nativa por RANGE (`inserted_at`): los
  `ALTER` sobre el padre cascadean a todas las particiones (existentes y
  futuras) y los índices se crean **en el padre con SQL crudo** — Postgres los
  propaga solo, igual que en `20260808055508_add_missing_indexes_to_request_logs`
  y `20260916225300_add_api_key_id_to_request_logs`.

  ## Sin FK a `users`

  La columna es un `uuid` crudo, sin `FOREIGN KEY`, como `api_key_id` y
  `credit_subscription_id`. Con `ON DELETE CASCADE` el histórico del usuario se
  borraría junto al usuario (el mismo mal que se está arreglando con
  `group_members`) y con `ON DELETE SET NULL` la columna quedaría vacía justo en
  las filas que deben sobrevivir al borrado. La evidencia histórica es el punto.

  ## Por qué un trigger, y no solo la escritura del proxy

  El proxy ya manda `user_id` en los 3 sitios que encolan `WriteWorker` y el
  worker lo propaga al attrs — ese es el camino normal y el trigger **no lo
  toca** (su `WHEN` corta antes: `NEW.user_id IS NULL`). El trigger existe para
  el resto de escritores (fixtures de test, cualquier `Logs.log_request/1`
  futuro): la invariante «toda fila con `group_member_id` tiene `user_id`» es una
  propiedad de la columna derivada, no una obligación de cada llamador. Sin él,
  un `INSERT` que olvide `user_id` deja una fila huérfana que la agregación por
  columna ya no ve — justo el bug que esta wave cierra.

  ## `flush/0` obligatorio (trampa que costó una corrida entera)

  Con `@disable_ddl_transaction true` el runner ejecuta `apply(module, :up, [])`
  y **solo después** `flush/0` (`Ecto.Migration.Runner.perform_operation/3`),
  así que todo `execute` de `up/0` queda **encolado**, no ejecutado. El backfill
  no es un comando de migración: es `Repo.query!` directo, y sin un `flush/0`
  explícito correría antes del `ALTER` — y como el error sube, el `flush/0` final
  tampoco corre y **no se aplica nada**, ni la columna. De ahí el `flush()`
  explícito entre la DDL y el backfill.

  ## Backfill

  Se hace **por partición y por lotes** (`@batch_size` filas por `UPDATE`), no
  en un `UPDATE` único sobre la tabla entera: la tabla es grande y un solo
  `UPDATE` sobre todas las particiones bloquearía y llenaría el WAL de golpe.
  El predicado `user_id IS NULL` hace el trabajo **idempotente y reanudable**:
  cada lote solo toca filas todavía sin poblar, así que un corte a mitad de
  camino se reanuda re-ejecutando la migración (todas las sentencias DDL usan
  `IF NOT EXISTS`/`IF EXISTS` por la misma razón — con `@disable_ddl_transaction`
  un `up/0` interrumpido no queda marcado como aplicado y se vuelve a correr
  entero).

  Verificación de huérfanos (probe portable para el operador, en producción):

      SELECT count(*) FROM request_logs
       WHERE group_member_id IS NOT NULL AND user_id IS NULL;

  Debe dar `0`.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Filas por UPDATE. Chico para que cada lote sea una transacción corta
  # (bloqueo y WAL acotados) sobre una tabla particionada grande.
  @batch_size 10_000

  def up do
    # 1. La columna. `IF NOT EXISTS` para que un `up/0` interrumpido (DDL sin
    #    transacción) pueda re-ejecutarse sin fallar en el ALTER ya aplicado.
    execute """
    ALTER TABLE request_logs ADD COLUMN IF NOT EXISTS user_id uuid
    """

    # 2. El trigger que mantiene la invariante en toda fila NUEVA (ver arriba).
    #    En el padre: Postgres lo clona a cada partición existente y a cada
    #    partición creada después (PartitionWorker).
    execute """
    CREATE OR REPLACE FUNCTION request_logs_set_user_id() RETURNS trigger AS $$
    BEGIN
      SELECT gm.user_id INTO NEW.user_id
        FROM group_members gm
       WHERE gm.id = NEW.group_member_id;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute "DROP TRIGGER IF EXISTS request_logs_set_user_id_trg ON request_logs"

    execute """
    CREATE TRIGGER request_logs_set_user_id_trg
      BEFORE INSERT ON request_logs
      FOR EACH ROW
      WHEN (NEW.user_id IS NULL AND NEW.group_member_id IS NOT NULL)
      EXECUTE FUNCTION request_logs_set_user_id()
    """

    # 3. `flush/0` EJECUTA lo encolado hasta aquí. Es obligatorio: con
    #    `@disable_ddl_transaction true` el runner hace `apply(module, :up, [])`
    #    y **después** `flush/0` (Ecto.Migration.Runner.perform_operation/3), así
    #    que todo `execute` dentro de `up/0` queda solo *encolado*. El backfill no
    #    es un comando de migración: es `Repo.query!`, y correría ANTES del
    #    `ALTER` (y si revienta, el `flush/0` final tampoco corre y no se aplica
    #    NADA — ni la columna). Sin este `flush` la migración no aplica nada.
    flush()

    # 4. El histórico: por join con `group_members`, por partición y por lotes.
    backfill_user_id()

    # 5. El índice del patrón de consulta de la agregación por usuario
    #    (WHERE user_id IN (...) AND inserted_at >= ...). Se crea DESPUÉS del
    #    backfill: así el UPDATE masivo no paga el mantenimiento del índice.
    execute """
    CREATE INDEX IF NOT EXISTS request_logs_user_inserted_idx
      ON request_logs (user_id, inserted_at)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_user_inserted_idx"
    execute "DROP TRIGGER IF EXISTS request_logs_set_user_id_trg ON request_logs"
    execute "DROP FUNCTION IF EXISTS request_logs_set_user_id()"
    execute "ALTER TABLE request_logs DROP COLUMN IF EXISTS user_id"
  end

  # ---------------------------------------------------------------------------
  # Backfill
  # ---------------------------------------------------------------------------

  defp backfill_user_id do
    Enum.each(request_logs_partitions(), fn partition ->
      backfill_partition(partition)
    end)
  end

  # Las particiones vivas del padre, leídas del catálogo: la lista no es fija
  # (PartitionWorker crea una por día).
  defp request_logs_partitions do
    Tokengate.Repo.query!(
      """
      SELECT c.relname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class p ON p.oid = i.inhparent
       WHERE p.relname = 'request_logs'
       ORDER BY c.relname
      """,
      [],
      log: false
    ).rows
    |> Enum.map(fn [name] -> safe_identifier!(name) end)
  end

  # El nombre sale del catálogo (no de input del usuario), pero se interpola en
  # SQL: se valida el alfabeto antes de tocarlo.
  defp safe_identifier!(name) do
    if name =~ ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/ do
      name
    else
      raise "unexpected partition identifier from catalog: #{inspect(name)}"
    end
  end

  # Idempotente y reanudable: cada lote toma `@batch_size` ctids que todavía
  # cumplen el predicado, así que termina solo cuando no queda ninguno. Un lote
  # sin filas = partición completa.
  defp backfill_partition(partition) do
    sql = """
    WITH batch AS (
      SELECT ctid FROM #{partition}
       WHERE group_member_id IS NOT NULL AND user_id IS NULL
       LIMIT $1
    )
    UPDATE #{partition} rl
       SET user_id = gm.user_id
      FROM group_members gm, batch
     WHERE rl.ctid = batch.ctid
       AND gm.id = rl.group_member_id
    """

    updated = Tokengate.Repo.query!(sql, [@batch_size], log: false).num_rows

    if updated > 0 do
      IO.puts("[add_user_id_to_request_logs] #{partition}: backfilled #{updated} rows")
      backfill_partition(partition)
    end
  end
end
