-- ============================================================================
-- Tokengate — probe de INTEGRIDAD post-migración (SOLO LECTURA)
--
-- Se corre en el servidor de producción DESPUÉS del deploy que aplicó la
-- migración «eliminar suscripciones», y su salida se compara contra la de
-- `pre_migration_baseline.sql`.
--
-- Cada consulta emite una columna `veredicto` con OK / REVISAR, para que el
-- operador no tenga que interpretar números a mano.
--
-- Uso:
--   psql "$DATABASE_URL" -f priv/repo/probes/post_migration_integrity.sql
-- ============================================================================

\pset pager off
\echo ''
\echo '=== 0. encabezado ==='
SELECT current_database() AS database,
       current_setting('server_version') AS pg_version,
       now() AS captured_at;

-- ----------------------------------------------------------------------------
-- CHECK 1 (P1) — cero columnas y cero FKs con `subscription`
--
-- `request_logs.credit_subscription_id` es la ÚNICA excepción deliberada:
-- se conserva como evidencia histórica del débito del modelo viejo.
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 1. COLUMNAS CON subscription (esperado: solo request_logs, 0 de tabla base) ==='
SELECT table_name || '.' || column_name AS columna,
       CASE
         WHEN table_name = 'request_logs' THEN 'OK (histórica, deliberada)'
         WHEN table_name LIKE 'request_logs\_%' THEN 'OK (partición)'
         ELSE 'REVISAR'
       END AS veredicto
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name LIKE '%subscription%'
ORDER BY 1;

\echo ''
\echo '=== CHECK 1b. Resto de columnas base con subscription (esperado: 0 filas) ==='
SELECT count(*) AS columnas_vivas,
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'REVISAR' END AS veredicto
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name LIKE '%subscription%'
  AND table_name NOT LIKE 'request_logs%';

\echo ''
\echo '=== CHECK 1c. FKs que referencian credit_subscriptions (esperado: 0 filas) ==='
SELECT conname, conrelid::regclass AS tabla,
       CASE WHEN to_regclass('public.credit_subscriptions') IS NULL THEN 'OK (tabla dropeada)'
            ELSE 'REVISAR' END AS veredicto
FROM pg_constraint
WHERE confrelid = to_regclass('public.credit_subscriptions');

\echo ''
\echo '=== CHECK 1d. La tabla credit_subscriptions ya no existe (esperado: NULL) ==='
SELECT to_regclass('public.credit_subscriptions') AS tabla,
       CASE WHEN to_regclass('public.credit_subscriptions') IS NULL THEN 'OK' ELSE 'REVISAR' END AS veredicto;

-- ----------------------------------------------------------------------------
-- CHECK 2 (P7) — la suma de `units` migrados == suma de límites + top-ups
--
-- Del baseline toma el total de unidades otorgadas por subs (recurrentes y
-- one-shot). Del post toma (límites mensuales por sujeto) + (amount_usd de
-- top-ups vigentes migrados). Las unidades son créditos = USD 1:1.
--
-- El operador debe correr el bloque POST con las cifras del baseline a mano
-- (el probe no lee el archivo; imprime los dos lados para compararlos).
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 2a. LADO POST: suma de límites mensuales migrados ==='
SELECT
  (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM groups)   AS limites_grupos_usd,
  (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM users)    AS limites_usuarios_usd,
  (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM services) AS limites_servicios_usd,
  (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM groups)
    + (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM users)
    + (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM services) AS total_limites_usd;

\echo ''
\echo '=== CHECK 2b. LADO POST: suma de top-ups migrados ==='
SELECT count(*) AS topups, COALESCE(sum(amount_usd), 0) AS total_topups_usd
FROM credit_topups;

\echo ''
\echo '=== CHECK 2c. TOTAL POST (límites + top-ups) — compáralo con la suma de units del baseline ==='
SELECT
  (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM groups)
  + (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM users)
  + (SELECT COALESCE(sum(monthly_spend_limit_usd), 0) FROM services)
  + (SELECT COALESCE(sum(amount_usd), 0) FROM credit_topups) AS total_migrado_usd,
  'compáralo con CHECK 2 del baseline (suma de units)' AS nota;

-- ----------------------------------------------------------------------------
-- CHECK 3 (P7) — nadie quedó sin camino de gasto
--
-- Un sujeto sin límite (`nil`), sin `unlimited_spend` y sin top-up vigente
-- está BLOQUEADO por diseño. La migración no debe crear esos casos: quien hoy
-- gastaba (estaba gateado) debe tener límite o estar ilimitado, y quien hoy
-- era tier 3 debe quedar `unlimited_spend = true`.
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 3a. SUJETOS BLOQUEADOS sin límite, sin ilimitado y sin top-up (esperado: 0 filas) ==='
SELECT 'grupo' AS nivel, g.id, g.name AS sujeto
FROM groups g
WHERE g.monthly_spend_limit_usd IS NULL AND g.unlimited_spend = false
  AND NOT EXISTS (SELECT 1 FROM group_members gm
                   JOIN credit_topups t ON t.user_id = gm.user_id
                  WHERE gm.group_id = g.id
                    AND t.status = 'active'
                    AND (t.expires_at IS NULL OR t.expires_at > now()))
UNION ALL
SELECT 'usuario', u.id, u.email
FROM users u
WHERE u.monthly_spend_limit_usd IS NULL AND u.unlimited_spend = false
  AND NOT EXISTS (SELECT 1 FROM credit_topups t
                   WHERE t.user_id = u.id
                     AND t.status = 'active'
                     AND (t.expires_at IS NULL OR t.expires_at > now()))
  AND NOT EXISTS (SELECT 1 FROM group_members gm
                   JOIN groups g ON g.id = gm.group_id
                  WHERE gm.user_id = u.id
                    AND (g.monthly_spend_limit_usd IS NOT NULL OR g.unlimited_spend = true))
UNION ALL
SELECT 'servicio', sv.id, sv.name
FROM services sv
WHERE sv.monthly_spend_limit_usd IS NULL AND sv.unlimited_spend = false
  AND NOT EXISTS (SELECT 1 FROM credit_topups t
                   WHERE t.service_id = sv.id
                     AND t.status = 'active'
                     AND (t.expires_at IS NULL OR t.expires_at > now()))
ORDER BY 1, 3;

\echo ''
\echo '=== CHECK 3b. Conteo de bloqueados por nivel (esperado: 0 en cada uno) ==='
SELECT
  (SELECT count(*) FROM groups g
    WHERE g.monthly_spend_limit_usd IS NULL AND g.unlimited_spend = false) AS grupos_sin_limite,
  (SELECT count(*) FROM users u
    WHERE u.monthly_spend_limit_usd IS NULL AND u.unlimited_spend = false) AS usuarios_sin_limite,
  (SELECT count(*) FROM services sv
    WHERE sv.monthly_spend_limit_usd IS NULL AND sv.unlimited_spend = false) AS servicios_sin_limite,
  CASE
    WHEN (SELECT count(*) FROM groups g WHERE g.monthly_spend_limit_usd IS NULL AND g.unlimited_spend = false) > 0
      OR (SELECT count(*) FROM services sv WHERE sv.monthly_spend_limit_usd IS NULL AND sv.unlimited_spend = false) > 0
    THEN 'REVISAR (un grupo/servicio sin límite bloquea a sus sujetos)'
    ELSE 'OK (los usuarios sin límite pueden heredar del grupo)'
  END AS veredicto;

-- ----------------------------------------------------------------------------
-- CHECK 4 (P7) — nadie gateado hoy quedó con límite CERO
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 4. LÍMITE CERO (esperado: 0 filas) ==='
SELECT 'grupo' AS nivel, g.name AS sujeto, g.monthly_spend_limit_usd
FROM groups g WHERE g.monthly_spend_limit_usd = 0
UNION ALL
SELECT 'usuario', u.email, u.monthly_spend_limit_usd
FROM users u WHERE u.monthly_spend_limit_usd = 0
UNION ALL
SELECT 'servicio', sv.name, sv.monthly_spend_limit_usd
FROM services sv WHERE sv.monthly_spend_limit_usd = 0
ORDER BY 1, 2;

\echo ''
\echo '=== CHECK 4b. Conteo de ceros (esperado: 0) ==='
SELECT
  (SELECT count(*) FROM groups WHERE monthly_spend_limit_usd = 0)
  + (SELECT count(*) FROM users WHERE monthly_spend_limit_usd = 0)
  + (SELECT count(*) FROM services WHERE monthly_spend_limit_usd = 0) AS limites_cero,
  CASE
    WHEN (SELECT count(*) FROM groups WHERE monthly_spend_limit_usd = 0)
       + (SELECT count(*) FROM users WHERE monthly_spend_limit_usd = 0)
       + (SELECT count(*) FROM services WHERE monthly_spend_limit_usd = 0) = 0
    THEN 'OK' ELSE 'REVISAR'
  END AS veredicto;

-- ----------------------------------------------------------------------------
-- CHECK 5 (P7 / P4) — keys conservadas y con dueño usuario
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 5a. KEYS POR USUARIO (comparar conteos con el baseline 4a) ==='
SELECT u.email, count(*) AS keys_activas
FROM api_keys k
JOIN group_members gm ON gm.id = k.group_member_id
JOIN users u ON u.id = gm.user_id
WHERE k.subject_type = 'member' AND k.status = 'active'
GROUP BY u.email
ORDER BY u.email;

\echo ''
\echo '=== CHECK 5b. KEYS POR SERVICIO (comparar con baseline 4b) ==='
SELECT sv.name, count(*) AS keys_activas
FROM api_keys k
JOIN services sv ON sv.id = k.service_id
WHERE k.subject_type = 'service' AND k.status = 'active'
GROUP BY sv.name
ORDER BY sv.name;

\echo ''
\echo '=== CHECK 5c. KEYS SIN user_id (esperado: 0 — el backfill no debe dejar huérfanas) ==='
-- Defensivo: si la columna `user_id` no existiera (migración no aplicada), el
-- probe reporta REVISAR en vez de abortar.
SELECT CASE
         WHEN EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public' AND table_name = 'api_keys'
                         AND column_name = 'user_id')
         THEN (SELECT count(*) FROM api_keys WHERE subject_type = 'member' AND user_id IS NULL)
         ELSE -1
       END AS keys_member_sin_user,
       CASE
         WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_schema = 'public' AND table_name = 'api_keys'
                             AND column_name = 'user_id')
           THEN 'REVISAR (la columna user_id no existe: migración no aplicada)'
         WHEN (SELECT count(*) FROM api_keys WHERE subject_type = 'member' AND user_id IS NULL) = 0
           THEN 'OK'
         ELSE 'REVISAR'
       END AS veredicto;

\echo ''
\echo '=== CHECK 5d. TOTALES DE KEYS (comparar con baseline 4c) ==='
SELECT subject_type, status, count(*) FROM api_keys GROUP BY 1, 2 ORDER BY 1, 2;

-- ----------------------------------------------------------------------------
-- CHECK 6 (P7) — accesos a modelos conservados
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 6. TOTALES DE ACCESOS (comparar con baseline 5b) ==='
SELECT 'group_models' AS tabla, count(*) FROM group_models
UNION ALL SELECT 'group_member_extra_models', count(*) FROM group_member_extra_models
UNION ALL SELECT 'group_member_denied_models', count(*) FROM group_member_denied_models
UNION ALL SELECT 'service_models', count(*) FROM service_models;

\echo ''
\echo '=== CHECK 6b. La tabla de denegados existe (esperado: 1 fila) ==='
SELECT count(*) AS tabla_existe,
       CASE WHEN count(*) = 1 THEN 'OK' ELSE 'REVISAR' END AS veredicto
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'group_member_denied_models';

\echo ''
\echo '=== CHECK 6c. La tabla de top-ups existe (esperado: 1 fila) ==='
SELECT count(*) AS tabla_existe,
       CASE WHEN count(*) = 1 THEN 'OK' ELSE 'REVISAR' END AS veredicto
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'credit_topups';

-- ----------------------------------------------------------------------------
-- CHECK 7 — inventario del modelo nuevo
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 7a. LÍMITES E ILIMITADOS POR NIVEL ==='
SELECT 'grupo' AS nivel, count(*) AS total,
       count(*) FILTER (WHERE monthly_spend_limit_usd IS NOT NULL) AS con_limite,
       count(*) FILTER (WHERE unlimited_spend) AS ilimitados,
       count(*) FILTER (WHERE monthly_spend_limit_usd IS NULL AND unlimited_spend = false) AS sin_limite_ni_ilimitado
FROM groups
UNION ALL
SELECT 'usuario', count(*),
       count(*) FILTER (WHERE monthly_spend_limit_usd IS NOT NULL),
       count(*) FILTER (WHERE unlimited_spend),
       count(*) FILTER (WHERE monthly_spend_limit_usd IS NULL AND unlimited_spend = false)
FROM users
UNION ALL
SELECT 'servicio', count(*),
       count(*) FILTER (WHERE monthly_spend_limit_usd IS NOT NULL),
       count(*) FILTER (WHERE unlimited_spend),
       count(*) FILTER (WHERE monthly_spend_limit_usd IS NULL AND unlimited_spend = false)
FROM services;

\echo ''
\echo '=== CHECK 7b. TOP-UPS MIGRADOS: vigentes vs vencidos ==='
SELECT status,
       count(*) AS total,
       count(*) FILTER (WHERE expires_at IS NULL OR expires_at > now()) AS vigentes,
       COALESCE(sum(amount_usd), 0) AS total_usd
FROM credit_topups
GROUP BY status
ORDER BY status;

\echo ''
\echo '=== FIN DE LA INTEGRIDAD — adjunta baseline + esta salida como evidencia del Gate 6 ==='
