defmodule Tokengate.Repo.Migrations.AddUserIdToRequestMetricsHourly do
  @moduledoc """
  Añade `user_id` a `request_metrics_hourly` y la mete a la clave única del
  bucket, para que las lecturas por usuario (dashboard, /stats/users) puedan
  servirse del rollup con la MISMA identidad que el motor de créditos
  (`request_logs.user_id`), tolerante a la rotación de membresías.

  ## La clave única

  El bucket hoy es `request_metrics_hourly_bucket_key UNIQUE NULLS NOT
  DISTINCT (day, hour_utc, group_member_id, model_id, provider_id)`.
  `NULLS NOT DISTINCT` es esencial: los logs de servicio y los post-rotación
  (FK ahora SET NULL) tienen `group_member_id` NULL, y dos buckets NULL
  distintos serían filas duplicadas. La nueva clave añade `user_id` al
  principio del vector — con DELETE+INSERT por hora en
  `Rollup.HourlyAggregate.aggregate_hours/2` la convergencia es completa: una
  re-agregación re-escribe el contenido íntegro de cada hora bajo la clave
  nueva, sin residuos de la vieja.

  El swap es: DROP CONSTRAINT viejo → ADD COLUMN → backfill → ADD CONSTRAINT
  nuevo. El constraint se re-agrega AL FINAL (después del backfill): si
  existieran duplicados bajo la clave nueva el ADD fallaría ruidosamente
  aquí, no en el primer upsert del RollupWorker a las 3am.

  ## Backfill (dos pasadas, ambas idempotentes)

  1. Miembros vivos: `user_id` desde `group_members`.
  2. Huérfanos (membresía ya borrada): `user_id` desde `audit_logs` —
     `group_member.add` registra `entity_id` = member.id y
     `changes.user_id`. Es la única copia superviviente del mapeo
     miembro→usuario para membresías purgadas por
     `20260917011526_one_monthly_sub_per_user`.

  Los huérfanos que tampoco estén en `audit_logs` quedan `user_id NULL`:
  siguen contando para los agregados org-wide (KPIs de /stats), pero ninguna
  vista por usuario los reclama — no se inventa atribución.

  La tabla NO es particionada: un solo par de UPDATE masivos vale, sin lotes.
  """

  use Ecto.Migration

  def up do
    # 1. La columna.
    execute "ALTER TABLE request_metrics_hourly ADD COLUMN IF NOT EXISTS user_id uuid"

    # 2. La clave vieja fuera — los upserts del worker aún no corren con
    #    user_id (deploy simultáneo), y la clave nueva aún no puede existir
    #    porque el backfill no terminó.
    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '5s';
      ALTER TABLE request_metrics_hourly
        DROP CONSTRAINT IF EXISTS request_metrics_hourly_bucket_key;
    END
    $$;
    """

    # 3. Backfill — miembros vivos.
    execute """
    UPDATE request_metrics_hourly r
       SET user_id = gm.user_id
      FROM group_members gm
     WHERE gm.id = r.group_member_id
       AND r.user_id IS NULL
    """

    # 4. Backfill — huérfanos vía audit_logs (mapeo miembro→usuario perdido).
    #    entity_id es texto: el binary_id del rollup se castea para comparar.
    #    Se toma el add MÁS RECIENTE por member id (DISTINCT ON, determinista:
    #    sin él, UPDATE...FROM con varias filas por entity_id elige una
    #    arbitraria).
    execute """
    UPDATE request_metrics_hourly r
       SET user_id = al.user_id
      FROM (
        SELECT DISTINCT ON (entity_id)
               entity_id,
               (changes ->> 'user_id')::uuid AS user_id
          FROM audit_logs
         WHERE entity_type = 'group_member'
           AND action = 'group_member.add'
           AND changes ? 'user_id'
         ORDER BY entity_id, inserted_at DESC
      ) al
     WHERE r.group_member_id::text = al.entity_id
       AND r.user_id IS NULL
    """

    # 5. La clave nueva, con la misma semántica NULLS NOT DISTINCT.
    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '5s';
      ALTER TABLE request_metrics_hourly
        ADD CONSTRAINT request_metrics_hourly_bucket_key UNIQUE NULLS NOT DISTINCT
          (day, hour_utc, user_id, group_member_id, model_id, provider_id);
    END
    $$;
    """

    # 6. Índice del patrón de lectura por usuario (user, hora).
    execute """
    CREATE INDEX IF NOT EXISTS request_metrics_hourly_user_idx
      ON request_metrics_hourly (day, hour_utc, user_id)
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '5s';
      ALTER TABLE request_metrics_hourly
        DROP CONSTRAINT IF EXISTS request_metrics_hourly_bucket_key;
    END
    $$;
    """

    execute """
    DO $$
    BEGIN
      SET LOCAL lock_timeout = '5s';
      ALTER TABLE request_metrics_hourly
        ADD CONSTRAINT request_metrics_hourly_bucket_key UNIQUE NULLS NOT DISTINCT
          (day, hour_utc, group_member_id, model_id, provider_id);
    END
    $$;
    """

    execute "DROP INDEX IF EXISTS request_metrics_hourly_user_idx"
    execute "ALTER TABLE request_metrics_hourly DROP COLUMN IF EXISTS user_id"
  end
end
