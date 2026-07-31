# 🔒 Security Audit Report — TokenGate

> Auditoría **read-only**. **Ningún archivo de producción fue editado.** Fecha: 2026-07-31.

## Executive Summary

- **Archivos revisados:** 88 `.ex` (capa web completa + contexts de negocio), ~11k LOC.
- **Hallazgos:** 9 totales — 0 críticos, **2 altos**, 3 medios, 4 bajos.
- **Código muerto:** 4 funciones públicas sin callers + confirmaciones.
- **Top 3:**
  1. `teams_live` y `services_live` validan admin **solo en mount** — los `handle_event` destructivos (delete/revoke) NO re-checkean, explotables por WebSocket directo.
  2. **Session fixation**: `login` e `impersonate` no renuevan el `session_id` (`configure_session(renew: true)` ausente).
  3. `provider_credentials.api_key_encrypted` es **plaintext en DB** (documentado "post-MVP" — decisión de producto pendiente).

**Lo que YA está bien blindado** (verificado, no reportar): OAuth (state con `Plug.Crypto.secure_compare`, allowlist fail-closed), `stats_export_controller` (team drill-down solo admin + scoping por member_ids), `models_live` (checkea `is_admin` en cada handler), `team_members_live` (valida ownership del member), `dashboard_live`/`api_keys_live` (validan member contra assigns), PubSub (debounce con `send_after` en alerts/credits/dashboard), proxy (doble throttle team+credential), parsers (`Decimal.parse`/`Integer.parse` con flash de error), forms de API keys (`type="password"` + masking).

---

## 🟠 HIGH

### H1 — `handle_event` destructivos sin re-check de admin (Teams, Services, Logs)
**Files:**
- `lib/tokengate_web/live/teams_live.ex:179` (`delete_team`), `:308` (`delete_webhook`), `:204` (`toggle_alias`) — 12 eventos
- `lib/tokengate_web/live/services_live.ex:100` (`delete_service`), `:142` (`revoke_key`), `:125` (`generate_key`), `:176` (`toggle_alias`) — 9 eventos
- `lib/tokengate_web/live/logs_live.ex` — sin attach_hook (2 eventos)

**Categoría:** Autorización / Defense-in-depth (skill 1b).

**Descripción:** Estas páginas validan `global_role == "admin"` únicamente en `mount/3` (teams_live:30, services_live:22). El `live_session :admin` del router protege la carga inicial y la navegación, **pero NO los eventos WebSocket subsecuentes**. Un cliente que haya montado la página como admin y luego pierda el rol, o que manipule el socket, puede disparar `phx-event` directo (`delete_team`, `revoke_key`, `delete_webhook`) sin que ningún handler re-valide el rol. No tienen el patrón `attach_hook(:require_admin, :handle_event, ...)` que SÍ usan `alerts/credits/providers/settings/users_live`.

**Evidencia:** `grep -c attach_hook` → teams_live=0, services_live=0, logs_live=0. Los handlers destructivos no contienen `global_role` ni `is_admin`.

**Fix sugerido:** añadir en `mount` de los 3 LiveViews el hook de todo-el-LiveView (ya probado en este repo):
```elixir
|> attach_hook(:require_admin, :handle_event, fn _event, _params, socket ->
  if socket.assigns.current_user.global_role == "admin" do
    {:cont, socket}
  else
    {:halt, put_flash(socket, :error, "No autorizado.")}
  end
end)
```
*Severidad: alta (no crítica) porque el router SÍ protege el acceso inicial — es un hueco de defense-in-depth, no una ruta abierta.*

---

### H2 — Session fixation en login e impersonación
**File:** `lib/tokengate_web/controllers/session_controller.ex:45-51` (`create`), `:143-147` (`impersonate`), `:174-178` (`stop_impersonating`); también `oauth_controller.ex:90-94` (`create_session`).

**Categoría:** Session management (OWASP A07).

**Descripción:** Tras autenticar, el código hace `put_session(:user_id, ...)` pero **nunca llama a `configure_session(conn, renew: true)`**. Esto significa que el `session_id` de la cookie se mantiene igual antes y después del login. Un atacante que fije el `session_id` de la víctima (vía XSS, subdominio, o cookie planting) puede secuestrar la sesión una vez que la víctima inicia sesión. Mismo problema en `impersonate` y `stop_impersonating` (cambian `:user_id` sin renovar).

**Evidencia:** `grep -n 'configure_session\|renew' session_controller.ex` → 0 coincidencias.

**Fix sugerido:** en cada punto donde se establece/ cambia `:user_id`:
```elixir
conn
|> configure_session(renew: true)
|> put_session(:user_id, user.id)
```
Aplicar en `create`, `impersonate`, `stop_impersonating`, y `OAuthController.create_session`.

---

## 🟡 MEDIUM

### M1 — `provider_credentials.api_key_encrypted` es plaintext en DB
**File:** `lib/tokengate/providers/credential.ex:25` + `lib/tokengate/proxy/openai_adapter.ex:34,61,129,151`.

**Categoría:** Secretos / encryption-at-rest (skill 4a).

**Descripción:** El campo se llama `api_key_encrypted` pero el moduledoc lo admite: *"stores the key as-is for now; encryption-at-rest is a post-MVP concern"*. Se lee en plaintext directo en el adapter. Cualquiera con acceso a la DB (backup, réplica, dump, SQL injection) obtiene todas las API keys de los providers (OpenAI, Anthropic, etc.). **Decisión de producto documentada — no se arregla sin orden explícita** (requiere migración + rotación de keys).

**Fix sugerido (cuando se decida):** `Cloak.Ecto` con vault AES-GCM, campo binario `api_key_ciphertext`, rotación en migración. Mientras tanto: restringir acceso a DB, cifrar backups, rotar keys si hay breach.

### M2 — LiveViews admin no re-verifican rol en `mount` (defense-in-depth)
**Files:** los 14 LiveViews de `live_session :admin` (stats, teams, services, logs, providers, users, models, alerts, credits, settings, team_members).

**Categoría:** Autorización / Defense-in-depth (skill 1a).

**Descripción:** Confían en que el `on_mount: :require_admin` del router los protege. Si el router se reconfigura (alguien mueve una ruta, o un futuro dev quita el live_session), el LiveView queda expuesto porque su `mount` no re-chequea. **Mitigado parcialmente**: teams/services sí validan en mount, models valida por-handler. Es el patrón correcto extenderlo a todos.

**Fix sugerido:** uniformar — todos los LiveViews admin deberían o bien validar `is_admin` en mount o usar `attach_hook`. *Severidad media porque el router SÍ los protege hoy.*

### M3 — Queries sin `limit` en tablas que crecen sin cota
**Files:** `lib/tokengate/metrics/rollup.ex` (22 `Repo.all` sin limit), `lib/tokengate/logs.ex:84,113,130,467`, `lib/tokengate/auditing.ex:87`.

**Categoría:** Performance / DoS potencial (skill 3).

**Descripción:** Los rollups de métricas y los listados de logs/audit no limitan filas. Con volumen alto de requests (es un proxy LLM), una query de rollup sobre 90d sin límite puede cargar miles de filas en memoria por dashboard conectado. No es crítico (requiere auth), pero bajo carga real es un riesgo de OOM/DB storm.

**Fix sugerido:** paginar logs/audit (cursor-based, ya tienen `@page_size` en logs_live), y agregar `LIMIT` defensivo en rollups o `LIMIT` por cohorte. Revisar caso por caso — algunos rollups agregan en SQL (GROUP BY) y devuelven pocas filas, esos están bien.

---

## 🟢 LOW

### L1 — `accounts.list_teams/0`, `list_team_members/0`, `list_api_keys/0`, `list_services/0` sin `limit`
**Files:** `lib/tokengate/accounts.ex:14,290,394,515`.

**Categoría:** Performance (skill 3).

**Descripción:** Funciones de listado administrativo sin paginación. Hoy con pocos equipos/usuarios no es problema; escala mal. Además `list_team_members/0`, `list_api_keys/0`, `list_services/0` **no tienen callers** (ver código muerto).

**Fix:** añadir `limit: 100` por defecto, o borrar las que no se usan.

### L2 — Inputs de secrets renderizan prefijo en alerts (info menor)
**File:** `lib/tokengate_web/live/alerts_live.ex:290,435,496` (`api_key_prefix(cred.api_key_encrypted)`).

**Categoría:** Secretos (skill 4c).

**Descripción:** Muestra el prefijo de la API key del credential en la tabla de alertas. Es solo el prefijo (primeros chars), no la key completa — riesgo bajo, pero el valor completo sí está en los assigns del LiveView (aunque enmascarado en HTML). Aceptable; solo documentar que el plaintext vive en memoria del socket.

**Fix (opcional):** precargar solo el prefijo, no el credential completo, en alerts.

### L3 — `sortable` drag en models_live no valida orden server-side estricto
**File:** `lib/tokengate_web/live/models_live.ex` (`SortableProviders` hook, líneas ~872-897).

**Categoría:** Input validation (bajo).

**Descripción:** El reorder por drag dispara eventos con el nuevo orden. Se valida `is_admin` ✓, pero conviene sanitizar que los ids reordenados pertenezcan al alias. Riesgo bajo (solo admin, y peor caso desordena prioridades).

### L4 — `dashboard_live` carga `model_catalog` completo en mount
**File:** `lib/tokengate_web/live/dashboard_live.ex:68` + `:879`.

**Categoría:** Performance (bajo).

**Descripción:** `assign(:model_catalog, [])` inicial pero luego `load_personal_data` puede cargar catálogo completo de aliases. Menor, solo si hay muchos modelos.

---

## 💀 Código Muerto (confirmado, sin callers)

| Función | Archivo | Evidencia |
|---|---|---|
| `Accounts.list_api_keys/0` | `accounts.ex:394` | 0 callers en lib/ y test/ |
| `Accounts.list_team_members/0` | `accounts.ex:290` | 0 callers (solo `list_team_members_for_team/user` sí se usan) |
| `Accounts.list_services/0` | `accounts.ex:515` | 0 callers |
| `Providers.list_credentials/0` | `providers.ex:108` | 0 callers |
| `Providers.list_team_member_extra_aliases/0` | `providers.ex:419` | 0 callers |

**Verificado:** `mix compile --warnings-as-errors` pasa limpio (EXIT 0) → no hay unused vars/aliases/defp. Estas son funciones **públicas** huérfanas (xref no las detecta automáticamente, las encontré por grep de callers).

**Fix:** borrar las 5 funciones (y sus tests si existen). Confirma que ninguna se llame por `apply/3` antes — no encontré uso dinámico.

**Hooks JS:** los 3 hooks (`SortableProviders`, `Modal`, `CopyToClipboard`) están registrados en `app.js:119` y todos usados en templates ✓ — no hay hooks muertos.

**Módulos:** todos los workers/supervisors (`budgets`, `metrics`, `routing`, `limits`, `observability`) están arrancados en `application.ex` ✓ — no hay módulos huérfanos.

---

## Summary Table

| Categoría | Crítico | Alto | Medio | Bajo | Total |
|---|---|---|---|---|---|
| Autorización / Defense-in-depth | 0 | 1 | 1 | 1 | 3 |
| Session management | 0 | 1 | 0 | 0 | 1 |
| Secretos / encryption | 0 | 0 | 1 | 1 | 2 |
| Performance / DoS | 0 | 0 | 1 | 2 | 3 |
| **Código muerto** | — | — | — | — | **5 funciones** |
| **Total hallazgos** | **0** | **2** | **3** | **4** | **9** |

---

## Remediation Priority

1. **Inmediato (alto):** H1 — attach_hook require_admin en teams_live, services_live, logs_live. H2 — `configure_session(renew: true)` en los 4 puntos de sesión.
2. **Urgente (medio):** M2 — uniformar validación de rol en LiveViews admin. M3 — revisar límites en rollups/logs.
3. **Decisión de producto:** M1 — encryption-at-rest para credentials (migración grande).
4. **Limpieza:** borrar las 5 funciones muertas.
5. **Cuando haya tiempo:** L1-L4 (bajos).

---

## Open questions para ti, Álvaro

1. **H1/H2 son claros y de bajo riesgo de romper** — ¿los arreglo ya tras tu OK, o quieres revisar el diff de cada uno primero?
2. **M1 (plaintext credentials)** — ¿lo dejamos como "found, decisión pendiente" o quieres que prepare el plan de migración a Cloak?
3. **Código muerto** — ¿borro las 5 funciones huérfanas en el mismo pase, o prefieres PR separado?
4. ¿Dónde guardo este reporte — solo chat, archivo en repo (sin commit), o página en Dran?

**Ningún archivo de producción fue editado durante esta auditoría. No hay commits ni push — esperando tu revisión.**
