# TokenGate — Plan de Fix Corregido y Mejorado

Revisión del reporte original contra el código real. Tres hallazgos eliminados
(inexistentes), uno reclasificado, el resto validado. Orden re-priorizado por
**riesgo real de producción** × **facilidad**, con dependencias explícitas.

Fecha de revisión: 2026-08-17

---

## Correcciones al reporte original

### Hallazgos eliminados (no existen en el código)

| # | Hallazgo original | Verificación | Veredicto |
|---|---|---|---|
| A12 | `flush_remaining` duplica `{:sse_done}` | `handle_event` setea `acc.done = true` al ver `[DONE]` (openai_adapter.ex:288); `flush_remaining` revisa `if acc.done` antes de reenviar (línea 313) | **Falso. No duplica.** |
| M8 | `subscription_id` FK huérfana en `request_logs` | Migración `20260726214614_remove_subscriptions.exs:10` ya dropeó la columna con `ALTER TABLE request_logs DROP COLUMN IF EXISTS subscription_id` | **Falso. Columna no existe.** |
| M15 | Índice en `model_providers.subscription_id` sin usar | La misma migración (línea 6) dropeó la columna `subscription_id` de `model_providers`; el índice se fue con ella | **Falso. Índice no existe.** |

### Hallazgos reclasificados

| # | Hallazgo original | Verificación | Veredicto |
|---|---|---|---|
| A11 | Chunks SSE sin sanitizar `\n\n` | El adapter splitea el stream por `\n\n` (`split_events` openai_adapter.ex:264), reensambla data lines con `\n` simple (`Enum.join(lines, "\n")` línea 283). El `chunk` que llega a `forward_stream_chunk` no contiene `\n\n` reales. Los newlines del contenido del LLM están escapados en JSON (`\n` como backslash-n). El framing `"data: #{chunk}\n\n"` es seguro. | **Sobreestimado. Reclasificar a Bajo** — solo edge case: JSON pretty-printed del provider (raro en LLM streaming). |
| A4 | Completion completo acumulado en RAM | Solo los chunks que contienen `"usage"` como texto (pocos en un stream normal) pasan por `decode_usage_chunk` y se acumulan en `acc.completion`. Los demás chunks (99%+) nunca se acumulan. El problema real es de **exactitud**, no de RAM: si el provider no envía usage frame, `acc.completion` solo tiene los delta texts de los chunks con `"usage"` — una fracción del stream — por lo que `TokenEstimator.estimate_completion` subestima los tokens del fallback. | **Reclasificar a Medio (exactitud de costos, no performance de RAM).** |

### Totales corregidos

| Severidad | Original | Corregido | Delta |
|-----------|----------|-----------|-------|
| 🔴 Crítico | 7 | 7 | 0 |
| 🟠 Alto | 16 | 12 | −4 (A12 eliminado, A11 reclasificado, A4 reclasificado) |
| 🟡 Medio | 18 | 17 | −1 (M8 eliminado) |
| 🟢 Bajo | 8 | 8 | 0 (+A11, −M15) |
| **Total** | **49** | **44** | **−5** |

---

## Hot path del proxy — cadena de llamadas por request

Antes de priorizar, mapeo lo que pasa en **cada request** del proxy hoy:

```
ProxyController.handle_proxy/2
  → route_and_acquire/5
    → Router.route/3
      → maybe_preload_team/1          [C7] 1 query DB (force: true)
      → Providers.list_accessible_aliases/1  [C6] 1-2 queries DB (sin cache)
      → route_alias/6
        → Routing.Cache.fetch_model_providers  (cached 60s ✓)
        → Routing.Cache.disabled_credential_ids  (cached 60s ✓)
        → Priority.select/2
          → sort_by_priority/1  [M5] N ETS lookups (CredentialHealth)
          → Enum.find/2 with available?
            → breaker.allow?/1 [M4] N Registry lookups + N gen_statem calls
    → check_spending/3
      → Budgets.record_spend/3 [C5] hasta 5 queries DB (first touch)
    → acquire_credential_limits/2
      → Limits.check_rate/2 [C2] 2 ETS reads (race con sweep)
      → Limits.acquire_concurrency/2

  → execute/stream
    → finish_stream/3
      → Budgets.record_spend/3         (si no se hizo en route)
      → Collector.record_request/1 [A1] 11-13 ETS update_counter + PubSub broadcast
```

**Sin fixes, cada request del proxy hace 2-7 queries síncronas a Postgres**
(C6 + C7 + C5) + 11-13 ops ETS (A1) + N Registry lookups (M4) + N ETS lookups (M5).

---

## Plan de ejecución — 4 fases

### Fase 1 — Quick wins (triviales, impacto inmediato en hot path)

Sin dependencias. Se pueden hacer en paralelo.

| # | Fix | Archivo | Cambio | Esfuerzo |
|---|-----|---------|--------|----------|
| 1.1 | **C7** Quitar `force: true` de `maybe_preload_team` | `router.ex:388-391` | `if Ecto.assoc_loaded?(team_member.team), do: team_member, else: Repo.preload(...)` | 10 min |
| 1.2 | **A5** Drop índice ASC duplicado | nueva migración | `DROP INDEX request_logs_model_alias_inserted_idx` | 5 min |
| 1.3 | **M1** `read_concurrency: true` en 4 tablas | `window.ex:268,278`, `inflight.ex:303`, `included_waiter.ex:66` | Añadir `read_concurrency: true` al `:ets.new/2` | 15 min |
| 1.4 | **A13** Truncar `agent_type` a 255 | `api_auth.ex:88-92` | `String.slice(type, 0, 255)` antes de retornar (igual que `client_agent`) | 5 min |
| 1.5 | **A7** Índice parcial `status_code >= 400` | nueva migración | `CREATE INDEX ... ON request_logs (status_code) WHERE status_code >= 400` | 10 min |
| 1.6 | **A6** Índice en `credential_name` | nueva migración | `CREATE INDEX ... ON request_logs (credential_name, inserted_at)` | 10 min |
| 1.7 | **A8** Índice en `agent_type` | nueva migración | `CREATE INDEX ... ON request_logs (agent_type, inserted_at) WHERE agent_type IS NOT NULL` | 10 min |

**Total Fase 1:** ~1h de trabajo. Impacto: elimina 1 query DB por request (C7),
reduce contención ETS (M1), cierra vector de ataque (A13), acelera queries del
Rollup (A5-A8).

---

### Fase 2 — Hot path del proxy (queries DB en cada request)

Dependencias: C6 depende de que exista `Routing.Cache` (ya existe). C5 es
independiente. C1 es independiente pero necesita Oban.

| # | Fix | Archivo | Cambio | Esfuerzo | Depende de |
|---|-----|---------|--------|----------|------------|
| 2.1 | **C6** Cachear `list_accessible_aliases` | `providers.ex:612-636`, `router.ex:109` | Extender `Routing.Cache` con key `{:accessible_aliases, team_id, member_id}`, TTL 60s. Invalidar en `create/update/delete_team_member`, cambios en `TeamModelAlias` y `TeamMemberExtraAlias` | 2-3h | Routing.Cache existe ✓ |
| 2.2 | **C5** Single-flight en `ensure_loaded` | `budgets/manager.ex:431-486` | Antes de `seed_from_db`, hacer `:ets.insert_new(@table, {{:loading, key}, true})`. Si ya existe `:loading`, esperar con `:ets.lookup` poll (max 50ms). En `seed/3`, borrar el `:loading` marker. Reduce thundering herd en primer request de miembro nuevo. | 3-4h | — |
| 2.3 | **C1** Cron de particiones diarias | nuevo Oban worker `Tokengate.PartitionWorker` | Worker que crea particiones con 3 días de lookahead (`CREATE TABLE IF NOT EXISTS request_logs_YYYY_MM_DD PARTITION OF ...`) + job de cleanup de particiones > 90 días. Cron diario a medianoche UTC. | 3-4h | Oban ya configurado ✓ |

**Total Fase 2:** ~10h. Impacto: elimina 2-7 queries DB por request del proxy
(C6 + C5), habilita partition pruning (C1) que acelera TODAS las queries de
`request_logs` que tocan `inserted_at`.

**Dependencia crítica:** C1 desbloquea el beneficio real de A5-A8 y M9-M13 —
sin partition pruning, los índices nuevos y las queries optimizadas siguen
escaneando el default partition completo.

---

### Fase 3 — Proxy stream + recursión

Independientes entre sí. Se pueden hacer en paralelo.

| # | Fix | Archivo | Cambio | Esfuerzo | Depende de |
|---|-----|---------|--------|----------|------------|
| 3.1 | **A2** Loop iterativo en `route_and_acquire` | `proxy_controller.ex:584-633` | Reemplazar recursión con `Enum.reduce_while` sobre candidates pre-resueltos. Resolver todos los `Router.route` candidates upfront (con cache de C6) e iterar | 3-4h | C6 (Fase 2) |
| 3.2 | **A3** Filtrar false positives en `maybe_capture_usage` | `proxy_controller.ex:1192-1216` | Además de `:binary.match(chunk, "\"usage\"")`, verificar que el chunk tenga estructura de usage frame: `String.starts_with?(String.trim(chunk), "{")` Y contenga `"choices"` o `"usage"`. Evita decode en chunks de contenido | 1h | — |
| 3.3 | **A4 (reclasificado)** Corregir estimación de fallback | `proxy_controller.ex:1200-1216` | `acc.completion` solo acumula chunks con `"usage"`. Para que el fallback de `finish_stream` sea exacto, acumular TODOS los delta texts (no solo los con `"usage"`) — o mejor, contar chars acumulados en un contador en vez de una lista de strings | 2h | — |

**Total Fase 3:** ~7h. Impacto: elimina stack overflow potencial con N credentials
saturadas (A2), reduce CPU en streams largos (A3), corrige estimación de costos
cuando el provider no envía usage (A4).

---

### Fase 4 — LiveViews + queries analíticas

Menos urgentes (no afectan el hot path del proxy). Agrupadas por componente.

| # | Fix | Archivo | Cambio | Esfuerzo | Depende de |
|---|-----|---------|--------|----------|------------|
| 4.1 | **A14** Cachear queries en MonitorLive | `monitor_live.ex:327-452` | Cachear `day_stats_query` y `per_model_cost` con DashboardCache (5s TTL). Debounce PubSub refreshes (no encolar si ya hay uno pendiente). Mover `list_model_aliases` a assign en mount | 3-4h | DashboardCache existe ✓ |
| 4.2 | **A15** Optimizar `load_alert_data` | `monitor_live.ex:109-166, 168-220` | Reemplazar `from(p in Providers.Provider, select: p) |> Repo.all()` (línea 204) con un JOIN a `top_provider_query` o filtrar solo los providers que aparecen. Cachear `load_alert_data` con TTL 30s | 2-3h | — |
| 4.3 | **A16** Reducir queries en LogsLive | `logs_live.ex:89-104, 382-387` | Eliminar timer de 5s (`@summary_tick_interval_ms`) — redundante con debounce de PubSub. Cachear `top_models_card` y `top_users_card` con TTL 3s | 2h | — |
| 4.4 | **M9** `peak_concurrency` en SQL | `rollup.ex:1755-1761` | Reemplazar sweep line en Elixir con `PERCENTILE_CONT` o `MAX` sobre `latency_ms` en SQL. Limitar a 24h máx | 3h | C1 (Fase 2) |
| 4.5 | **M10** `rpm_stats_per_member` en SQL | `rollup.ex:1895-1942` | Mover `Enum.group_by`/`Enum.max`/`Enum.sum` a `MAX`/`AVG`/`percentile_cont` en SQL | 3h | — |
| 4.6 | **M11** `breakdown_by_credential` con JOINs | `rollup.ex:1114-1232` | Mergear queries 2 y 3 (resolución de nombres de providers y credentials) como JOINs en la query principal | 2-3h | — |
| 4.7 | **M12** `total_spend_by_user` con filtro temporal | `logs.ex:586-592` | Añadir `WHERE inserted_at >= ^from` default 30 días | 30 min | — |
| 4.8 | **M13** CostBackfill batch | `logs/cost_backfill.ex:78-92` | Reemplazar `Enum.reduce` con `Repo.update_all` por batches usando `FROM (VALUES ...)` | 2h | — |

**Total Fase 4:** ~18h. Impacto: reduce carga de Postgres en dashboards
(A14-A16), acelera queries analíticas (M9-M13).

---

### Fase 5 — Limpieza y hardening (no bloqueante)

Puede hacerse en cualquier momento, sin dependencias.

| # | Fix | Archivo | Cambio | Esfuerzo |
|---|-----|---------|--------|----------|
| 5.1 | **M2** Guard contra reset de budget en `bump_counter` | `budgets/manager.ex:508-515` | Si el default object se crea (entry evicted), loguear warning. Considerar `heir` en la tabla (B4) para prevenir evicción | 1-2h |
| 5.2 | **M3** StickyTracker: batch delete en vez de cast por entry | `routing/sticky_tracker.ex:69` | Acumular expired keys y hacer un `:ets.select_delete` batch cada N accesos | 1h |
| 5.3 | **M6** `stable_prefix` O(n) → O(n) con MapSet | `proxy/prompt_optimizer.ex:34-57` | Reemplazar `Enum.reduce` + `Enum.any?` con `MapSet` de contents normalizados | 30 min |
| 5.4 | **M7** Drop columnas legacy de `request_logs` | nueva migración | `ALTER TABLE request_logs DROP COLUMN IF EXISTS cost_usd, DROP COLUMN IF EXISTS savings_usd, DROP COLUMN IF EXISTS estimated_cost_usd`. Actualizar `merge_legacy_cost_keys/2` para solo warning | 1h |
| 5.5 | **B1** Guard en `Window.snapshot` | `metrics/window.ex:82` | Añadir `ensure_table()` antes de `tab2list`, o `case :ets.whereis(@table)` guard | 10 min |
| 5.6 | **B2** `Inflight.count_by_model` con match_spec | `logs/inflight.ex:161-228` | Reemplazar `select` + `Enum.group_by` con match_spec que cuente por modelo | 1h |
| 5.7 | **B3** Sweep en `dashboard_cache` | `metrics/dashboard_cache.ex` | Añadir `handle_info(:sweep, state)` que borre entradas expiradas cada 5 min | 30 min |
| 5.8 | **B4** Heir en tablas ETS de GenServers | `collector.ex`, `budgets/manager.ex`, etc. | Añadir `{:heir, pid, nil}` en `:ets.new` para sobrevivir crashes del GenServer | 2h |
| 5.9 | **B5** `numeric(12,4)` en lugar de `(12,6)` | nueva migración | `ALTER TABLE ... ALTER COLUMN provider_cost_usd TYPE numeric(12,4)` | 30 min |
| 5.10 | **B7** No exponer 8 chars de API key real | `monitor_live.ex:238-242` | Usar un hash determinista (ej. `:crypto.hash(:md5, encrypted) |> Base.encode16 |> String.slice(0, 8)`) en vez de los chars reales | 30 min |
| 5.11 | **B8** Extraer helpers de formato a módulo | nuevo `TokengateWeb.FormatHelpers` | Mover `format_number`, `format_decimal`, `format_compact`, etc. e importar en las 4 LiveViews | 1h |

**Total Fase 5:** ~11h.

---

## Resumen de dependencias

```
Fase 1 (quick wins) ─── sin dependencias ─────────────────────► ejecutar ya
  │
  ├─ C7 (quitar force:true) ──► reduce queries en Fase 2
  │
Fase 2 (hot path DB)
  │
  ├─ C6 (cache accessible_aliases) ──► desbloquea A2 (Fase 3.1)
  ├─ C5 (single-flight budgets)  ──► independiente
  └─ C1 (cron particiones)       ──► desbloquea M9, M10, M11, M12 (Fase 4)
                                    + beneficio real de A5-A8 (Fase 1)
                                    + M7, M14 (limpieza de columnas legacy)

Fase 3 (proxy stream) ─── A2 depende de C6
  │
Fase 4 (LiveViews) ─── M9-M12 dependen de C1 para beneficio real
  │
Fase 5 (hardening) ─── sin dependencias, anytime
```

---

## Lo que NO está en este plan (del reporte original)

| # | Razón |
|---|------|
| A12 | **No existe el bug.** `flush_remaining` revisa `acc.done` antes de reenviar `{:sse_done}`. |
| A11 | **Sobreestimado.** El adapter ya sanitiza: splitea por `\n\n` y reensambla con `\n` simple. El framing del output es seguro. Reclasificado a Bajo en Fase 5 si se quiere cubrir el edge case de JSON pretty-printed. |
| A4 | **Mal descrito.** No es un problema de RAM (solo chunks con `"usage"` se acumulan). El problema real es de exactitud de estimación de tokens del fallback. Reclasificado a Fase 3.3. |
| M8 | **No existe.** `subscription_id` ya fue dropeado de `request_logs` por la migración `20260726214614`. |
| M15 | **No existe.** `subscription_id` fue dropeado de `model_providers` por la misma migración; el índice se fue con la columna. |
| M14 | **Bajo valor.** Los ALTERs con `@disable_ddl_transaction` ya se ejecutaron. Solo relevante si se agregan columnas nuevas. No hay acción presente. |

---

## Métrica de éxito

Después de Fases 1-2, medir:

1. **Queries DB por request del proxy:** objetivo **0** en steady state (con caches calientes). Hoy: 2-7.
2. **Latencia p99 del proxy:** objetivo **< 50ms** sin contención. Hoy: depende de DB round-trips.
3. **Partition pruning:** verificar con `EXPLAIN` que `WHERE inserted_at >= now() - interval '5 min'` escanea solo la partición del día, no el default. Hoy: escanea el default completo.
4. **Ops ETS por request:** objetivo **reducir de 11-13 a 8-10** (tras throttle de broadcast de A1, fase futura).

Después de Fase 4, medir:

5. **Queries DB por dashboard conectado cada 5s:** objetivo **2-3** (con cache). Hoy: 6-10 en MonitorLive.
6. **Tiempo de mount de LogsLive:** objetivo **< 500ms**. Hoy: puede ser segundos sin pruning.
