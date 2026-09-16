-- ============================================================================
-- Tokengate — probe de BASELINE pre-migración (SOLO LECTURA)
--
-- Se corre en el servidor de producción ANTES del deploy que aplica la
-- migración «eliminar suscripciones». No escribe nada: solo fotografía el
-- estado del modelo viejo para poder compararlo después contra
-- `post_migration_integrity.sql`.
--
-- Uso:
--   psql "$DATABASE_URL" -f priv/repo/probes/pre_migration_baseline.sql
-- o, desde el release:
--   bin/tokengate eval 'Tokengate.Probes.run_pre_migration_baseline()'
--
-- Guarda la salida completa: es la evidencia del Gate 6 (claim P7).
-- ============================================================================

\pset pager off
\echo ''
\echo '=== 0. encabezado ==='
SELECT current_database() AS database,
       current_setting('server_version') AS pg_version,
       now() AS captured_at;

-- ----------------------------------------------------------------------------
-- 1. Sujetos por nivel con su estado de gate HOY
--
-- Espeja `Credits.grants_for/1`: un miembro está GATEADO (tiene crédito con
-- tope) si su grupo tiene una sub default O él tiene una sub directa. Sin
-- ninguno de los dos cae a tier 3 (hoy: ilimitado).
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== 1a. GRUPOS — sub default y cuántos miembros gatea ==='
SELECT g.id,
       g.name,
       g.default_subscription_id AS sub_id,
       s.name AS sub_name,
       s.units,
       s.recurrence,
       s.status,
       s.expires_at,
       (SELECT count(*) FROM group_members gm WHERE gm.group_id = g.id) AS members,
       CASE
         WHEN g.default_subscription_id IS NULL THEN 'tier3 (ilimitado hoy)'
         WHEN s.status = 'paused' THEN 'gateado (pausada)'
         WHEN s.expires_at IS NOT NULL AND s.expires_at <= now() THEN 'gateado (vencida)'
         ELSE 'gateado (activa)'
       END AS estado_hoy
FROM groups g
LEFT JOIN credit_subscriptions s ON s.id = g.default_subscription_id
ORDER BY g.name;

\echo ''
\echo '=== 1b. USUARIOS — membresías, sub directa y estado de gate ==='
SELECT u.id,
       u.email,
       u.status,
       (SELECT count(*) FROM group_members gm WHERE gm.user_id = u.id) AS memberships,
       (SELECT string_agg(g.name, ' + ' ORDER BY g.name)
          FROM group_members gm JOIN groups g ON g.id = gm.group_id
         WHERE gm.user_id = u.id) AS grupos,
       (SELECT count(*) FROM group_members gm JOIN groups g ON g.id = gm.group_id
         WHERE gm.user_id = u.id AND g.default_subscription_id IS NOT NULL) AS en_grupo_gateado,
       (SELECT count(*) FROM credit_subscriptions s
         WHERE s.user_id = u.id AND s.recurrence = 'monthly') AS subs_directas,
       (SELECT count(*) FROM credit_subscriptions s
         WHERE s.user_id = u.id AND s.recurrence = 'none') AS topups,
       (SELECT COALESCE(sum(s.units), 0) FROM credit_subscriptions s
         WHERE s.user_id = u.id AND s.recurrence = 'monthly') AS units_directas,
       CASE
         WHEN (SELECT count(*) FROM group_members gm JOIN groups g ON g.id = gm.group_id
                WHERE gm.user_id = u.id AND g.default_subscription_id IS NOT NULL) > 0
           THEN 'gateado (grupo)'
         WHEN (SELECT count(*) FROM credit_subscriptions s WHERE s.user_id = u.id) > 0
           THEN 'gateado (directa)'
         ELSE 'tier3 (ilimitado hoy)'
       END AS estado_hoy
FROM users u
ORDER BY u.email;

\echo ''
\echo '=== 1c. SERVICIOS — sub directa y estado de gate ==='
SELECT sv.id,
       sv.name,
       sv.group_id,
       sv.subscription_id AS sub_id,
       s.name AS sub_name,
       s.units,
       s.status,
       s.expires_at,
       CASE
         WHEN sv.subscription_id IS NULL THEN 'tier3 (ilimitado hoy)'
         WHEN s.status = 'paused' THEN 'gateado (pausada)'
         WHEN s.expires_at IS NOT NULL AND s.expires_at <= now() THEN 'gateado (vencida)'
         ELSE 'gateado (activa)'
       END AS estado_hoy
FROM services sv
LEFT JOIN credit_subscriptions s ON s.id = sv.subscription_id
ORDER BY sv.name;

-- ----------------------------------------------------------------------------
-- 2. units de cada sub y su remanente estimado
--
-- El remanente se mide como el gasto ATRIBUIDO a la sub en los logs
-- (`request_logs.credit_subscription_id`), que es la verdad durable del modelo
-- viejo. Para subs de grupo la atribución es por usuario (join a group_members,
-- igual que `spend_between/4`); para subs de servicio, por `service_id`.
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== 2. UNITS + GASTO ATRIBUIDO + REMANENTE POR SUB ==='
SELECT s.id,
       s.name,
       s.user_id,
       s.units,
       s.recurrence,
       s.status,
       s.starts_at,
       s.expires_at,
       s.reset_day,
       s.rollover_mode,
       s.rollover_pct,
       s.rollover_cap_units,
       COALESCE((SELECT sum(rl.provider_cost_usd) FROM request_logs rl
                  WHERE rl.credit_subscription_id = s.id), 0) AS gasto_atribuido_usd,
       GREATEST(s.units::numeric
                - COALESCE((SELECT sum(rl.provider_cost_usd) FROM request_logs rl
                             WHERE rl.credit_subscription_id = s.id), 0),
                0) AS remanente_aprox_unidades
FROM credit_subscriptions s
ORDER BY s.name;

-- ----------------------------------------------------------------------------
-- 3. Top-ups vigentes (los que SÍ se migran a `credit_topups`)
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== 3. TOP-UPS VIGENTES (recurrence=none, active, no vencidos) ==='
SELECT s.id, s.name, s.user_id, s.service_id,
       s.units, s.status, s.starts_at, s.expires_at,
       COALESCE((SELECT sum(rl.provider_cost_usd) FROM request_logs rl
                  WHERE rl.credit_subscription_id = s.id), 0) AS gasto_atribuido_usd,
       GREATEST(s.units::numeric - COALESCE((SELECT sum(rl.provider_cost_usd) FROM request_logs rl
                                              WHERE rl.credit_subscription_id = s.id), 0), 0)
         AS remanente_a_migrar_unidades
FROM credit_subscriptions s
LEFT JOIN services sv ON sv.subscription_id = s.id
WHERE s.recurrence = 'none'
  AND s.status = 'active'
  AND (s.expires_at IS NULL OR s.expires_at > now())
ORDER BY s.name;

\echo ''
\echo '=== 3b. TOP-UPS NO VIGENTES (no se migran) ==='
SELECT s.id, s.name, s.user_id, s.units, s.status, s.expires_at,
       CASE
         WHEN s.expires_at IS NOT NULL AND s.expires_at <= now() THEN 'vencido'
         WHEN s.status <> 'active' THEN 'pausado'
         ELSE 'agotado o sin remanente'
       END AS motivo
FROM credit_subscriptions s
WHERE s.recurrence = 'none'
  AND (s.status <> 'active' OR (s.expires_at IS NOT NULL AND s.expires_at <= now()))
ORDER BY s.name;

-- ----------------------------------------------------------------------------
-- 4. API keys por usuario y por servicio (conteo — la migración las conserva)
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== 4a. KEYS POR USUARIO ==='
SELECT gm.user_id, u.email, count(*) AS keys_activas
FROM api_keys k
JOIN group_members gm ON gm.id = k.group_member_id
JOIN users u ON u.id = gm.user_id
WHERE k.subject_type = 'member' AND k.status = 'active'
GROUP BY gm.user_id, u.email
ORDER BY u.email;

\echo ''
\echo '=== 4b. KEYS POR SERVICIO ==='
SELECT k.service_id, sv.name, count(*) AS keys_activas
FROM api_keys k
JOIN services sv ON sv.id = k.service_id
WHERE k.subject_type = 'service' AND k.status = 'active'
GROUP BY k.service_id, sv.name
ORDER BY sv.name;

\echo ''
\echo '=== 4c. TOTALES DE KEYS ==='
SELECT subject_type, status, count(*) FROM api_keys GROUP BY 1, 2 ORDER BY 1, 2;

-- ----------------------------------------------------------------------------
-- 5. Accesos a modelos por sujeto (la migración los conserva)
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== 5. ACCESOS A MODELOS POR SUJETO ==='
SELECT 'grupo' AS nivel, g.id AS sujeto_id, g.name AS sujeto, count(*) AS accesos
FROM group_models gm JOIN groups g ON g.id = gm.group_id GROUP BY 1, 2, 3
UNION ALL
SELECT 'miembro-extra', grm.id, COALESCE(u.email, grm.id::text), count(*)
FROM group_member_extra_models gx
JOIN group_members grm ON grm.id = gx.group_member_id
LEFT JOIN users u ON u.id = grm.user_id
GROUP BY 1, 2, 3
UNION ALL
SELECT 'servicio', sv.id, sv.name, count(*)
FROM service_models sm JOIN services sv ON sv.id = sm.service_id GROUP BY 1, 2, 3
ORDER BY 1, 3;

\echo ''
\echo '=== 5b. TOTALES DE ACCESOS ==='
SELECT 'group_models' AS tabla, count(*) FROM group_models
UNION ALL SELECT 'group_member_extra_models', count(*) FROM group_member_extra_models
UNION ALL SELECT 'service_models', count(*) FROM service_models;

-- ----------------------------------------------------------------------------
-- 6. Anomalías que la migración debe tolerar
-- ----------------------------------------------------------------------------
\echo ''
\echo '=== 6a. SUBS CON units = 0 (el backfill NO debe dejar a nadie en cero) ==='
SELECT s.id, s.name, s.user_id, s.status, s.recurrence
FROM credit_subscriptions s WHERE s.units = 0
ORDER BY s.name;

\echo ''
\echo '=== 6b. SUBS CON reset_day <> 1 (pasan a mes calendario UTC) ==='
SELECT s.id, s.name, s.units, s.reset_day, s.status,
       COALESCE((SELECT sum(rl.provider_cost_usd) FROM request_logs rl
                  WHERE rl.credit_subscription_id = s.id), 0) AS gasto_total
FROM credit_subscriptions s
WHERE s.reset_day IS NOT NULL AND s.reset_day <> 1
ORDER BY s.name;

\echo ''
\echo '=== 6c. SUBS COMPARTIDAS POR VARIOS SERVICIOS (regla: replicar monto) ==='
SELECT sv.subscription_id, count(*) AS servicios,
       string_agg(sv.name, ' + ' ORDER BY sv.name) AS nombres
FROM services sv
WHERE sv.subscription_id IS NOT NULL
GROUP BY sv.subscription_id
HAVING count(*) > 1;

\echo ''
\echo '=== 6d. SUBS CON ROLLOVER (el carry se pierde — decisión del usuario) ==='
SELECT s.id, s.name, s.units, s.rollover_mode, s.rollover_pct, s.rollover_cap_units,
       (SELECT count(*) FROM credit_subscriptions x WHERE x.id = s.id) AS n
FROM credit_subscriptions s
WHERE s.rollover_mode = 'rollover'
ORDER BY s.name;

\echo ''
\echo '=== 6e. USUARIOS EN MAS DE UN GRUPO GATEADO (keys múltiples al migrar) ==='
SELECT u.email, count(*) AS grupos_gateados,
       string_agg(g.name, ' + ' ORDER BY g.name) AS grupos
FROM group_members gm
JOIN users u ON u.id = gm.user_id
JOIN groups g ON g.id = gm.group_id
WHERE g.default_subscription_id IS NOT NULL
GROUP BY u.email
HAVING count(*) > 1;

\echo ''
\echo '=== 6f. COLUMNAS Y FKs CON subscription (debe reflejar el estado PRE) ==='
SELECT table_name || '.' || column_name AS columna
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name LIKE '%subscription%'
  AND table_name NOT LIKE 'request_logs_2%'
ORDER BY 1;

SELECT conname, conrelid::regclass AS tabla
FROM pg_constraint
WHERE confrelid = 'credit_subscriptions'::regclass
ORDER BY 1;

\echo ''
\echo '=== FIN DEL BASELINE — guarda esta salida como evidencia del Gate 6 ==='
