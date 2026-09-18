# Auditoría — plan de log de acciones

Registrar **quién hizo qué, sobre qué y cuándo**, consultable por el
administrador, con **retención de 90 días**. Alcance: **todo lo que un admin
puede hacer** (mutaciones de escritura) **+ autenticación**.

## Decisiones (fijadas)

| Tema | Decisión |
|---|---|
| Alcance v1 | Escrituras administrativas **+ autenticación** (login/logout/fallos de login) |
| Contexto por entrada | IP + User-Agent + rol del actor **+ usuario suplantado** |
| Retención | Particiones mensuales + *drop* de particiones > 90 días (patrón `Logs.PartitionWorker`) |
| Visor | Página admin `/operations/audit` con filtros + export CSV |

Fuera de v1: lectura de secretos (`credential.secret_reveal`) y export CSV como
evento auditado.

## Estado actual

Infra ya existente en `lib/tokengate/auditing/`:

- Tabla `audit_logs` append-only (`inserted_at`, sin `updated_at`) con
  `user_id` (nullable = acción de sistema), `action`, `entity_type`,
  `entity_id` (string), `changes` (map). Índices por `user_id`,
  `(entity_type, entity_id)`, `inserted_at`.
- `Tokengate.Auditing.audit/5` y `list_audit_logs/1` (filtros por user/entidad/
  acción, tope 100, **sin rango de fechas ni paginación**).
- Cobertura real: **~19 acciones en 6 sitios** (`users_live`, `services_live`,
  `providers_live`, `dashboard_live`, `global_cap_live`, `maintenance_live`,
  `session_controller`).
- **Sin auditar en absoluto**: `ModelsLive`, `LabsLive`, `GroupsLive`,
  `GroupMembersLive`, `TopupsLive`, `ObservabilityLive`, alta/baja de
  proveedores/servicios y **todo el ciclo de autenticación**.

Convención de nombres ya en uso: `entidad.accion` (p. ej. `user.create`,
`credential.toggle_status`, `impersonate.start`).

---

## Actividades de usuario que se registran

La pregunta operativa: *¿qué se loguea de un usuario?* Hay que distinguir dos
papeles, porque el "quién" es distinto en cada uno.

### 1. El usuario como **ACTOR** — lo que él mismo hace

| Acción | Origen | Estado |
|---|---|---|
| `auth.login` (éxito) | `SessionController.create` | ➕ |
| `auth.login_failed` (email + IP; ya hay rate-limit por IP) | `SessionController.create` | ➕ |
| `auth.logout` | `SessionController.delete` | ➕ |
| `auth.google_login` (alta o acceso vía OAuth) | `OAuthController.callback` | ➕ |
| `auth.password_change` (su propia contraseña, con re-auth) | `save_password` | ➕ |
| `user.update` (perfil propio: nombre, timezone) | perfil | parcial (`user.update` existe vía admin) |
| `api_key.create` / `api_key.revoke` / `api_key.replace` (sus propias keys) | `/dashboard` | create/revoke ✅ · replace ➕ |
| `routing.clear_sticky` (sobre sí mismo) | `/dashboard` | ✅ |

### 2. El usuario como **OBJETO** — lo que un administrador hace sobre él

| Acción | Estado |
|---|---|
| `user.create` | ✅ |
| `user.update` (rol, status, techo de gasto, límites conc/RPM) | ✅ (falta diff) |
| `user.toggle_status` (activar/suspender) | ✅ |
| `user.delete` | ✅ |
| `user.reset_password` (admin → usuario) | ✅ |
| `impersonate.start` / `impersonate.stop` | ✅ |
| `api_key.create` / `api_key.revoke` en su nombre | ✅ |
| `group_member.add` / `group_member.remove` (asignarlo a un perfil de límites) | ➕ |
| `exemption.add` / `exemption.remove` (exención de tope diario) | ➕ |
| `topup.create` / `topup.update` / `topup.toggle_status` / `topup.revoke` (crédito extra) | ➕ |
| `budget.update_global_daily_cap` (afecta a todos) | ✅ |

---

## Inventario exhaustivo de acciones admin (derivado del código)

Cada fila es un `handle_event` **mutante** de una LiveView admin (o controlador
gated admin). Los eventos puramente de UI (búsqueda, orden, filtro, abrir/cerrar
modal, paginar, elegir en un picker, cambiar de tab) **no se auditan**.

✅ = ya existe · ➕ = falta · 🔧 = existe pero con el detalle incompleto.

### Catálogo → Proveedores (`providers_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_provider` (create/update) | `provider.create` / `provider.update` ➕ 🔧 (incluye límites `max_rpm`, `max_concurrent`, `max_concurrent_per_user`, `receive_timeout_ms`) |
| `delete_provider` | `provider.delete` ➕ |
| `toggle_provider` | `provider.toggle_status` ➕ |
| `save_paths` | `provider.paths_update` ➕ (overrides de rutas) |
| `activate_catalog_provider` | `provider.activate_catalog` ➕ |
| `save_credential` (create/update) | `credential.create` ✅ / `credential.update` ✅ |
| `toggle_credential` | `credential.toggle_status` ✅ |
| `reactivate_credential` | `credential.reactivate` ➕ |
| `reset_breaker` | `credential.breaker_reset` ➕ |
| `delete_credential` | `credential.delete` ➕ |

> "API keys de proveedores" = **credentials**. Cubiertas a medias: create/update/
> toggle sí; reactivar, reset de breaker y borrar no.

### Catálogo → Modelos (`models_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_model` (create/update) | `model.create` / `model.update` ➕ |
| `delete_model` | `model.delete` ➕ |
| `toggle_pin` | `model.pin_toggle` ➕ |
| `save_guard_rails` | `model.guard_rails_update` ➕ (guard_rails, prompt_cache, lazy_cleanup) |
| `save_new_credential` (inline) | `credential.create` ➕ (crea credential desde aquí) |
| `save_model_provider` (create/update) | `model_provider.create` / `model_provider.update` ➕ (incluye scope) |
| `toggle_model_provider` | `model_provider.toggle_status` ➕ |
| `delete_model_provider` | `model_provider.delete` ➕ |
| `reorder_providers` | `model_provider.reorder` ➕ |
| scope en `save_model_provider` | `model.access_scope_change` ➕ (grupos/miembros con acceso) |

### Catálogo → Labs (`labs_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_lab` (create/update) | `lab.create` / `lab.update` ➕ |
| `delete_lab` | `lab.delete` ➕ |

### Acceso → Usuarios (`users_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_user` → alta | `user.create` ✅ |
| `save_edit_user` | `user.update` 🔧 **diff incompleto**: `Map.take` solo toma `name/global_role/status`; faltan `monthly_spend_limit_usd`, `unlimited_spend`, `default_concurrency_limit`, `default_rpm_limit` y el cambio de perfil de límites (`sync_user_sub`) |
| `save_password` | `user.reset_password` ✅ |
| `toggle_status` | `user.toggle_status` ✅ |
| `confirm_delete_user` | `user.delete` ✅ |
| `create_key` | `api_key.create` ✅ |
| `revoke_user_key` | `api_key.revoke` ✅ |
| `clear_user_sticky_routes` | `routing.clear_sticky` ✅ |

### Acceso → Servicios (`services_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_service` (create/update) | `service.create` / `service.update` ➕ |
| `delete_service` | `service.delete` ➕ |
| `toggle_model` | `service.model_access_toggle` ➕ |
| `add_supervisor` | `service_supervisor.add` ➕ |
| `remove_supervisor` | `service_supervisor.remove` ➕ |
| `create_service_key` | `api_key.create` ✅ |
| `revoke_service_key` | `api_key.revoke` ✅ |
| `clear_service_sticky_routes` | `routing.clear_sticky` ✅ |

### Presupuesto → Perfiles de límites (`groups_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_group` (create/update) | `group.create` / `group.update` ➕ (límites: `default_concurrency_limit`, `default_rpm_limit`, `monthly_spend_limit_usd`, `unlimited_spend`) |
| `delete_group` | `group.delete` ➕ |
| `toggle_model` | `group.model_access_toggle` ➕ |

### Presupuesto → Membresía del perfil (`group_members_live.ex`)
| Handler | Acción audit |
|---|---|
| `add_member` | `group_member.add` ➕ |
| `remove_member` | `group_member.remove` ➕ |
| `toggle_extra_model` | `group_member.model_access_change` ➕ |
| `save_alias_extra` | `group_member.extra_model_update` ➕ |

### Presupuesto → Top-ups (`topups_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_topup` (create/update) | `topup.create` / `topup.update` ➕ |
| `toggle_topup_status` | `topup.toggle_status` ➕ |
| `revoke_topup` | `topup.revoke` ➕ |

### Presupuesto → Tope diario global (`global_cap_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_global_cap` | `budget.update_global_daily_cap` ✅ |
| `add_global_exemption` | `exemption.add` ➕ |
| `remove_global_exemption` | `exemption.remove` ➕ |

### Operaciones → Observabilidad (`observability_live.ex`)
| Handler | Acción audit |
|---|---|
| `save_destination` (create/update) | `destination.create` / `destination.update` ➕ |
| `delete_destination` | `destination.delete` ➕ |

### Operaciones → Mantenimiento (`maintenance_live.ex`)
| Handler | Acción audit |
|---|---|
| `reset_logs` | `settings.reset_logs` ✅ |
| `reset_sticky_sessions` | `settings.reset_sticky_sessions` ✅ |
| `refresh_catalog` | `settings.catalog_refresh` ✅ |

### Operaciones → Monitoreo (`monitoring_live.ex`)
Solo lectura (`filter`, `load_more`). **Nada que auditar.**

### Fuera de las LiveViews admin
| Handler | Acción audit |
|---|---|
| `SessionController.create` | `auth.login` / `auth.login_failed` ➕ |
| `SessionController.delete` | `auth.logout` ➕ |
| `OAuthController.callback` | `auth.google_login` ➕ |
| cambio de contraseña propia | `auth.password_change` ➕ |
| `SessionController.impersonate` / `stop_impersonating` | `impersonate.start` ✅ / `impersonate.stop` ✅ |


---

## Modelo de datos

### Campos nuevos en `audit_logs`

| Campo | Tipo | Para qué |
|---|---|---|
| `actor_email` | string | Etiqueta desnormalizada; **sobrevive al borrado del usuario** (la FK es `SET NULL`) |
| `actor_role` | string | `global_role` en el momento de la acción |
| `acting_as_id` | binary_id (null) | Usuario suplantado (la sesión va «como él») |
| `acting_as_email` | string (null) | Etiqueta del usuario suplantado |
| `ip` | string | IP del actor (resolviendo `X-Forwarded-For` tras el proxy) |
| `user_agent` | string | User-Agent del cliente |
| `origin` | string | `web` \| `system` \| `worker` \| `api` |
| `target_label` | string | Etiqueta humana de la entidad (email, nombre, prefijo de key) |
| `changes` | map | Diff **antes/después** redactado (ver abajo) |

Se conservan `user_id`, `action`, `entity_type`, `entity_id`.

**Quién es el actor:** `user_id` / `actor_email` / `actor_role` son siempre el
**humano responsable** — el admin si la entrada se hizo bajo una suplantación,
si no el usuario de la sesión. El usuario suplantado vive en `acting_as_*` (y es
`nil` fuera de una suplantación). Así «quién hizo qué» nombra al responsable,
nunca a la víctima.

### Redacción (nunca escribir en claro)
`password` / `password_hash`, tokens de API key y secretos de credencial,
datos de tarjeta. En `changes` va el **nombre del campo**, no su valor, cuando el
campo es sensible.

### Particionado y retención

Convertir `audit_logs` en tabla **RANGE particionada por `inserted_at`**,
particiones **mensuales**, y un worker que:

1. Crea por adelantado la partición del mes en curso + siguiente.
2. Hace *detach/drop* de particiones con más de 90 días (≈ conserva 3-4 meses).

Caveat de Postgres: en una tabla particionada **toda PK/unique debe incluir la
clave de partición** → PK compuesta `(id, inserted_at)` (no la `id` sola actual).
Migrar en dos pasos: crear la tabla nueva particionada → copiar → intercambiar,
con backfill del histórico existente a la partición del mes que corresponda.

Endurecimiento append-only: trigger que rechace `UPDATE`/`DELETE` sobre
`audit_logs` (hoy la inmutabilidad es solo convención del contexto).

## API de captura

Sustituir las llamadas posicionales `audit(user, action, type, id, changes)` por
una forma con contexto:

```elixir
Auditing.log(actor, action, entity, changes, ctx)
```

donde `ctx` lleva `ip`, `user_agent`, `origin`, `target_label` y —clave—
`acting_as` (el usuario suplantado, si lo hay). El **actor** que se pasa es ya
el responsable: `TokengateWeb.Audit` lo resuelve (admin si `assigns.impersonator`
está presente, si no el usuario de la sesión). Los productores del contexto:

- **Plug** en el pipeline `:browser`: extrae IP (con `X-Forwarded-For`), UA y
  lee `:impersonator_id` de la sesión (ya la escribe `SessionController`).
- **`on_mount` hook** en `live_session`: replica lo anterior para sockets
  (reconexiones no re-ejecutan plugs).
- Rutas/workers de sistema: `origin: "system"`, `actor: nil`.

### Impersonación (resuelto)
`TokengateWeb.Audit` resuelve el actor como **el humano responsable**: si la
sesión es una suplantación (`assigns.impersonator` presente), el actor es el
**admin** y el usuario suplantado se guarda en `acting_as_*`. La resolución vive
en la capa web (`audit/5` desde socket, `audit_conn/5` desde conn), no en el
contexto, que solo escribe lo que le pasan.

## Visor admin — `/operations/audit`

LiveView en `live_session :admin` (`UserAuth.require_admin`).

- Tabla con: fecha, actor (email+rol), impersonador, acción, entidad +
  `target_label`, IP, y detalle de `changes`.
- Filtros: rango de fechas, actor, `entity_type`, `action`, `target_label`, IP.
- Paginación server-side.
- Export CSV vía controlador (patrón `StatsExportController`).
- Extender `Auditing.list_audit_logs/1`: rango de fechas + paginación (hoy tope
  100, sin fechas).

## Orden de implementación sugerido

1. **Migración + modelo**: campos nuevos, PK compuesta, particionado, trigger
   append-only. Retro-compatible (columnas nullable).
2. **Contexto**: plug + `on_mount` + `Auditing.log/5`; migrar los ~19 sitios
   existentes a la nueva API sin cambiar acciones.
3. **Auth** (`SessionController`, `OAuthController`, cambio de contraseña) —
   cierra el bloque de autenticación.
4. **Cobertura de escritura admin**: el inventario exhaustivo de arriba
   (`providers_live`, `models_live`, `labs_live`, `services_live`,
   `groups_live`, `group_members_live`, `topups_live`, `global_cap_live`,
   `observability_live`) + arreglar el diff de `user.update`.
5. **Retención**: worker de particiones de `audit_logs`.
6. **Visor** `/operations/audit` + export.

Cada paso con `mix precommit` verde y tests de que la entrada se escribe con
actor/contexto correctos.
