# Paridad usuario ↔ servicio — plan

> **SUPERSEDED por `docs/homologacion-perfiles.md`** (2026-09-16).
>
> Qué de este doc sigue vigente y qué ya no:
>
> - **P1 (plegar `extra_concurrency`/`extra_rpm`) — HECHO**:
>   `20260917033703_fold_member_extras_into_user.exs`; `GroupMember` ya no tiene
>   los campos. **Su §4.4 y §4.6 quedan obsoletos.**
> - **P3 (read-side de crédito simétrico) — HECHO**: `Budgets.list_service_budgets/0`
>   ya expone `has_credit?`, `credit_remaining_usd`, `remaining_topup_usd`.
> - **P0 — resuelto** por P1 (eliminar, no devolver UI).
> - **W4 / idea extra (`request_logs.user_id`) — HECHO**:
>   `20260917033650_add_user_id_to_request_logs.exs`.
> - **§8 (CASCADE de `group_member_id`) — sigue ABIERTO**. El plan nuevo lo
>   recomienda resolver en la misma migración que el rename, para no pasar dos
>   veces por la tabla más grande.
> - **§7 (inventario de tablas, paginado, deriva columna por columna) — VIGENTE**
>   y absorbido por el doc nuevo.
> - Todo el vocabulario «grupo» de este doc **queda obsoleto** por D1:
>   la entidad pasa a llamarse **Perfil de límites**.
>
> El doc nuevo es autocontenido; este se conserva por el inventario de §7 y el
> análisis de §8.

Objetivo: que **usuario** y **servicio** sean dos encarnaciones del mismo
concepto (**sujeto que gasta**) y compartan estructura donde aplique:
gestión de modelos, concurrencia, RPM, ilimitado, límite mensual, top-ups,
crédito, y las mismas vistas de detalle y stats.

Fecha: 2026-09-16 · Base: `main`. El WIP que este plan describe como pendiente
quedó commiteado en `6cd3cf4` (una sub mensual por usuario + observabilidad
global) y `259141e` (limpiar sticky a nivel sujeto); ver §8 para el delta.

---

## 1. Punto de partida: qué ya es simétrico

Antes de tocar nada, el inventario honesto. **La mitad del modelo ya está
unificada** y no hay que rehacerla:

| Pieza | Estado | Evidencia |
|---|---|---|
| Sujeto de gasto | ✅ `{:user, id} \| {:service, id}` | `lib/tokengate/credits.ex:101` (`@type subject`) |
| Plan de crédito | ✅ `%{subject, limit_usd, unlimited?, topups}` | `lib/tokengate/credits.ex:94-99` |
| Semántica de nulos (`nil` = hereda/no hay, `0` = cero, `unlimited_spend` = único camino) | ✅ documentada y única | `lib/tokengate/credits.ex:14-23` |
| Enforcement ETS (reserve/settle/release, límite + top-up + cap global) | ✅ una sola máquina | `lib/tokengate/budgets/manager.ex:194-254` |
| Top-ups | ✅ misma tabla, check «exactamente un dueño» | `lib/tokengate/credits/topup.ex:97-108` |
| API keys polimórficas (`subject_type`) | ✅ misma tabla | `lib/tokengate/accounts/api_key.ex:16-27` |
| Atribución de la key en logs | ✅ `request_logs.api_key_id` | `lib/tokengate/logs/request_log.ex:61` |
| Cache de auth del proxy | ✅ resuelve user **y** service por hash | `lib/tokengate/accounts.ex:1234-1260` |
| Picker de modelos | ✅ mismo componente `<.model_picker>` | `group_members_live.ex:716`, usado con `granted_ids` |

Conclusión: **el enforcement ya es uno solo.** La asimetría no está en el
motor de gasto — está en los **límites de tráfico (conc/RPM)**, las **keys**,
el **acceso a modelos** y las **vistas**.

---

## 2. Las asimetrías reales (con evidencia)

### A2.1 — Conc/RPM: 3 niveles aditivos vs 1 nivel absoluto ⚠️ la peor

> **Estado tras `6cd3cf4` (verificado):** la UI de extras se retiró
> (`group_members_live.ex` ya no tiene el form de overrides ni pide
> extra conc/RPM al dar de alta), **pero `extra_concurrency` / `extra_rpm`
> siguen en el schema `GroupMember` y `effective_limits/1` los sigue
> sumando**. La deriva sigue abierta: es una fuente de límites inalcanzable
> desde la aplicación, sólo escribible por DB/seeds. P0/P1 abajo siguen
> pendientes y son la decisión a tomar (eliminarlos o devolverles UI).

| | Usuario | Servicio |
|---|---|---|
| Modelo | grupo (5/60) **+** `extra_*` del miembro | absoluto (5/60 si nil) |
| Código | `combine_integer(group.default_*, member.extra_*)` | `absolute_limit(service.*, key)` |
| Ubicación | `lib/tokengate/accounts.ex:1177-1178` | `lib/tokengate/accounts.ex:1185-1190` |

Es asimétrico en **dos** sentidos: (1) el usuario *suma dos fuentes*, el
servicio no suma nada; (2) el usuario tiene **override propio** en el modelo
(`users.default_concurrency_limit` / `default_rpm_limit`, migración
`20260916193823`) **que nadie lee** — es código muerto:

```
$ grep -rn "default_concurrency_limit" lib/ | grep -v group.default
lib/tokengate/accounts/user.ex:34        # el campo
lib/tokengate/accounts/user.ex:81,97,131 # validaciones
# ninguna lectura en effective_limits ni en el proxy
```

Y el WIP ya commiteado **quitó la UI** de extras pero **`effective_limits`
los sigue sumando** → hoy hay una fuente de límites inalcanzable desde la UI,
solo escribible por DB/seeds.

### A2.2 — API keys: N con label vs 1 sola

| | Usuario | Servicio |
|---|---|---|
| Cardinalidad | N keys activas por `user_id` | 1 (`has_one :api_key`, `service.ex:33`) |
| Gestión | `create_key`/`revoke_user_key` + modal (`users_live.ex:432,476,1270`) | `generate_service_api_key` **reemplaza in-place** (`accounts.ex:885`) |
| Lectura | `list_api_keys_for_user/1` (`accounts.ex:718`) | `list_api_keys_for_service/1` **ya existe** (`accounts.ex:727`) |

`list_api_keys_for_service/1` existe y no se usa → el read-side ya está listo.
El `label` ya está en el esquema (`api_key.ex:21`) y la migración
`20260916193825` lo añadió para ambos sujetos.

### A2.3 — Acceso a modelos: 3 estados vs 1 estado

| | Usuario | Servicio |
|---|---|---|
| Tablas | `group_models` ∪ `group_member_extra_models` − `group_member_denied_models` | `service_models` a secas |
| Contrato | `{models, extra_ids, denied_ids}` | `{models, [], []}` (hardcodeado) |
| Código | `providers.ex:1094` | `providers.ex:1071` |
| Origen | grupo (sub mensual) = **contenedor** | sin contenedor |

La asimetría de fondo: **el usuario tiene contenedor (el grupo), el servicio
no.** Eso no se arregla copiando tablas.

### A2.4 — Read-side de crédito en `/stats`

`Budgets.member_budget/3` (`budgets.ex:389-410`) expone
`has_credit?`, `credit_remaining_usd`, `unlimited?`, `remaining_topup_usd`.
`Budgets.list_service_budgets/0` (`budgets.ex:100-121`) **no expone** ni
`has_credit?` ni `credit_remaining_usd`. Misma información de origen, dos
shapes distintos.

### A2.5 — Tablas de stats: mismas columnas… casi

| Columna | `/stats/users` | `/stats/services` |
|---|---|---|
| Sujeto (link) | ✅ `stats/users.ex:74` | ✅ `stats/services.ex:418` |
| Relación | «Grupos» (`users.ex:87`) | — **falta** (¿«Supervisores»?) |
| Requests / Costo / Tokens in / out / TPS | ✅ | ✅ |
| Cache % | — **falta** | ✅ (`services.ex:483`) |
| Costo / req | ✅ (`users.ex:159`) | — **falta** |
| Barra de presupuesto | «Crédito · ciclo» (`users.ex:161`) | «Presupuesto · mes» (`services.ex:507`) |

Mismo dato, dos etiquetas y dos tooltips (`users.ex:163-170` explica la
herencia de grupo; `services.ex:507` no).

### A2.6 — Páginas de detalle: gemelas divergidas

`UserStatsLive` y `ServiceStatsLive` se declaran espejo mutuo
(`service_stats_live.ex:6`) pero un diff normalizado da **278 líneas**.
Diferencias estructurales, no cosméticas: el usuario agrega **N membresías**
(`group_member_ids`), el servicio filtra por **`service_id`**.

### A2.7 — Asimetrías intencionales (declarar, no arreglar)

- **Supervisores**: `/services/supervised[/:id]` da acceso read-only a un
  no-admin. No hay análogo para usuarios (`router.ex:120-126`). Es correcto:
  un servicio es infra compartida, un usuario es una persona.
- **Grupo/sub**: solo existe para usuarios. Es el contenedor.

---

## 3. Modelo objetivo: `propio || contenedor || default`

Una sola regla de resolución para **todo** límite, en ambos sujetos:

```
efectivo = propio_del_sujeto  ||  default_del_contenedor  ||  default_del_módulo
```

| Sujeto | propio | contenedor | default |
|---|---|---|---|
| Usuario | `users.default_*`, `users.monthly_spend_limit_usd` | el grupo (sub) | 5 / 60 |
| Servicio | `services.*` | — (no tiene) | 5 / 60 |

Esto hace que **gasto y tráfico usen la misma semántica de nulos**, que es lo
que hoy no pasa: el gasto ya resuelve `propio → contenedor`
(`credits.ex:58-75`) y el tráfico no.

---

## 4. Plan por fases

Cada fase es un PR atómico y verificable con `mix precommit`. Dependencias
explícitas al final.

### P0 — Cerrar la deriva abierta (sin código nuevo)

Decidir el destino de `group_member.extra_concurrency` / `extra_rpm`: hoy
sin UI, todavía sumados en `effective_limits`. **Recomendado: eliminarlos**
(P1 los pliega). Si se decide mantenerlos, hay que devolverles UI —
cualquier otra opción deja un campo medio muerto.

- [x] Resolver el WIP actual (commiteado en `6cd3cf4` + `259141e`).
- [ ] Decidir `extra_*`: eliminar (recomendado) o devolver UI. **Pendiente.**
- [ ] Test que fije el comportamiento: miembro con `extra_rpm: 30` en grupo
      5/60 → 90 hoy. Ese test se **reescribe** en P1.

### P1 — Conc/RPM simétrico (2 niveles)

**Cambios:**

1. **Migración de datos** (`mix ecto.gen.migration fold_member_extras_into_user`):
   ```sql
   UPDATE users u
   SET default_concurrency_limit = g.default_concurrency_limit + COALESCE(gm.extra_concurrency, 0),
       default_rpm_limit          = g.default_rpm_limit          + COALESCE(gm.extra_rpm, 0)
   FROM group_members gm JOIN groups g ON g.id = gm.group_id
   WHERE gm.user_id = u.id;
   ```
   Solo para usuarios sin override propio (`default_* IS NULL`), para no
   pisar valores ya fijados. Después `DROP COLUMN extra_concurrency, extra_rpm`.

2. `Accounts.effective_limits/1` (`accounts.ex:1164-1188`): sustituir
   `combine_integer/2` por la regla `propio || contenedor || default`:
   ```elixir
   def effective_limits(%GroupMember{} = m) do
     g = m.group
     %{
       concurrency_limit: first_integer([m.user.default_concurrency_limit, g.default_concurrency_limit, 5]),
       rpm_limit:         first_integer([m.user.default_rpm_limit,         g.default_rpm_limit,         60])
     }
   end
   ```
   Cuidado: hoy `effective_limits(%GroupMember{})` **no preloadea `:user`**
   (solo `:group`, `accounts.ex:1159`). Hay que añadirlo, y eso **cambia el
   shape del `auth_entry`** → `ApiKeyCache` (`api_key_cache.ex:12`) debe
   incluir el user preloadeado. **Este es el punto de riesgo del plan.**

3. `GroupMember` schema: quitar `extra_concurrency`/`extra_rpm` (`group_member.ex:16-17`)
   y sus validaciones (`:38-39`).

4. `UsersLive`: añadir inputs «Concurrencia» / «RPM» al form de edición
   (`users_live.ex:976-1010`), con los mismos hints que `services_live.ex:686-696`
   («Límite absoluto; vacío = hereda del grupo»).

5. `GroupMembersLive`: la columna «Límites» (`:585-594`) hoy muestra
   `@group.default_*` crudo. Pasa a mostrar el **efectivo** del miembro
   (badge cuando es override propio), igual que `services_live`.

6. `User` schema: los campos ya existen y ya están en `@permitted` (`user.ex:48`);
   ahora **se usan por primera vez**. Mantener las validaciones `greater_than: 0`.

7. Tests a tocar: `accounts_test.exs`, `api_key_cache_test.exs`,
   `budgets/manager_test.exs`, `proxy_controller_test.exs:251-252` (usan
   `default_*` de grupo como única fuente → siguen válidos), más un test
   nuevo del override por usuario y otro de la herencia.

**Resultado:** usuario y servicio resuelven tráfico con la misma regla; un
nivel menos; cero campos muertos.

### P2 — N keys por servicio (paridad con usuario)

El read-side ya existe (`list_api_keys_for_service/1`). Falta el write-side
y la UI.

1. `Service`: `has_one :api_key` → `has_many :api_keys` (`service.ex:33`).
   Mantener un `has_one :api_key` **derivado** no es posible en Ecto; los
   usos (`services_live.ex:80,365,381,784`) migran a la lista.
2. `Accounts`: `create_service_api_key/2` (insert con `label`, mismo patrón
   que `create_api_key/1`) y deprecar `generate_service_api_key/1`
   (`accounts.ex:885`) o reimplementarlo como «crear la primera».
   `revoke_service_api_key/1` (`:936`) ya sirve.
3. **Extraer el modal de keys** de `users_live.ex:1270-1310` a
   `lib/tokengate_web/components/keys_modal.ex` (componente con
   `subject_kind`, `subject_id`, `keys`, `spend_by_key`). `services_live`
   lo consume con `subject_kind="service"`. Simetría literal, no aproximada.
4. `ApiKey.changeset` (`api_key.ex:32-42`): sin cambios, ya valida service.
5. Hot path (**proxy**): **cero cambios**. El cache resuelve por hash de
   token (`accounts.ex:1229`), no por cardinalidad.
6. Tests: `services_live_test.exs`, `topups_live_test.exs` (los top-ups ya
   aceptan ambos dueños, `topups_live.ex:192-222` ✓).

### P3 — Read-side de crédito simétrico

1. `Budgets.list_service_budgets/0` (`budgets.ex:100-121`): añadir
   `has_credit?`, `credit_remaining_usd` y `limit_spend_usd` (hoy
   `monthly_spend_usd` ya es el gasto contra límite, pero el nombre no lo
   dice). Igualar los campos al `member_budget` de `budgets.ex:392-410`.
2. `@type service_budget` (`budgets.ex:129-138`) se alinea.
3. Sin cambios en `Stats.budget_bar/budget_badge` — ya son compartidos
   (`stats_helpers.ex:804`).

### P4 — Stats: misma tabla, mismo detalle

**Tablas (`/stats`):**

1. Unificar etiqueta a **«Crédito · ciclo»** y el tooltip de usuarios
   (`stats/users.ex:161-170`) en ambas; el de servicios dice otra cosa.
2. Añadir «Costo / req» a `/stats/services` (`stats/services.ex:507`) —
   `cost_per_request/1` ya existe en `stats/users.ex:268`.
3. Añadir «Cache %» a `/stats/users` (ya está en servicios,
   `stats/services.ex:483`); el dato está en el breakdown.
4. Añadir columna relacional a servicios: «Supervisores» (equivalente a
   «Grupos»), alimentada por `service_supervisors`.

**Páginas de detalle:**

5. Extraer `<.SubjectStats>` de `UserStatsLive` + `ServiceStatsLive`:
   - props: `subject_kind`, `subject`, `member_ids`, `page_title`, `back_path`, `back_label`
   - el filtro de logs cambia de `log.group_member_id in member_ids` a
     `log.service_id == id` según `subject_kind`
   - todo lo demás (KPI strip, breakdown, stream, filtros) es **idéntico**
   - objetivo: de 278 líneas de deriva a ~40 de adapter
6. `SupervisedServiceStatsLive` **no** se toca (asimetría intencional,
   §A2.7), pero puede consumir el mismo componente con `read_only: true`.

### P5 — `Tokengate.Subjects` (opcional, el cierre)

Fachada única que devuelve **un solo map** para ambos sujetos:

```elixir
defmodule Tokengate.Subjects do
  @type description :: %{
    subject: Credits.subject(),
    kind: :user | :service,
    label: String.t(),
    limit_usd: Decimal.t() | nil,
    unlimited?: boolean(),
    concurrency_limit: pos_integer(),
    rpm_limit: pos_integer(),
    topups: [map()],
    remaining_topup_usd: Decimal.t(),
    keys: [ApiKey.t()],
    models: [Model.t()],
    spend: %{...},
    has_path?: boolean()
  }

  @spec describe(Credits.subject()) :: description()
end
```

Consumido por `UsersLive`, `ServicesLive`, `UserStatsLive`,
`ServiceStatsLive`. Es lo que hace literal el «misma estructura en lo que
aplique»: una sola función, dos entradas, una salida.

**Nota de coste:** P5 no añade capacidad nueva — consolida P1-P4. Si P1-P4
ya dejan las vistas compartiendo componentes, P5 es cosmético y **opcional**.

---

## 5. Idea extra (fuera de las 5 fases): `request_logs.user_id`

Hoy el agregado por usuario exige un `join` a `group_members`:

```elixir
# credits.ex:245-250
RequestLog
|> join(:inner, [rl], gm in GroupMember, on: gm.id == rl.group_member_id)
|> where([rl, gm], gm.user_id == ^user_id)
```

El servicio, en cambio, lee su columna directa (`credits.ex:239-243`).
**Asimetría de esquema en la tabla de verdad** (`request_logs`), con dos
costes reales:

1. **Performance**: `spend_grouped_users` (`credits.ex:208`) paga el join en
   cada agregado; el servicio no.
2. **Corrección**: si un usuario cambia de sub (la migración
   `20260917011526` hace 1 user = 1 sub **y borra las membresías
   duplicadas en cascada, con sus request_logs** — §`one_monthly_sub_per_user`),
   su historia deja de ser continua. Con `user_id` en el log, la historia
   sobrevive al cambio de sub.

Propuesta: `add :user_id, :binary_id` a `request_logs` + backfill por join +
escribirlo en el proxy (ya se conoce el user en `build_auth_entry`). Efecto:
el agregado por usuario pasa a ser una lectura directa, **idéntica** a la del
servicio.

Es la asimetría más profunda del sistema y la que más se paga.

---

## 6. Orden, dependencias y riesgo

```
P0 ──> P1 ──┬──> P4 ──> P5 (opcional)
            ├──> P2
            └──> P3
```

| Fase | Depende de | Riesgo | Motivo |
|---|---|---|---|
| P0 | — | bajo | decisión, no código |
| P1 | P0 | **alto** | toca datos + cambia el shape del `auth_entry` (hot path) |
| P2 | P1 | bajo | el proxy no cambia |
| P3 | — | bajo | solo read-side |
| P4 | P1-P3 | medio | refactor de UI, sin lógica nueva |
| P5 | P1-P4 | bajo | consolidación, no capacidad |
| extra | P1 | medio | migración de tabla particionada (`request_logs`) |

**Punto de riesgo único de P1**: `effective_limits/1` hoy no preloadea
`:user` (`accounts.ex:1159`). Al añadirlo, el mapa que se guarda en
`ApiKeyCache` cambia de forma y hay que invalidar el cache
(`api_key_cache.ex:28-42` documenta el contrato de invalidación). Test de
regresión obligatorio: `api_key_cache_test.exs:107` ya prueba que editar el
grupo invalida; hace falta el gemelo para editar el **usuario**.

**Lo que NO se toca** (asimetría correcta): el "contenedor" es un concepto
solo de usuarios. No se le inventa un contenedor a los servicios, ni tres
tablas de modelos, ni supervisores a los usuarios.

---

## 7. Inventario de tablas: columnas, orden, filtros y paginado

### 7.1 Estado real de cada tabla (verificado)

#### Gestión (Acceso / Crédito)

| # | Ruta | Columnas | Orden por | Filtros | Paginado |
|---|---|---|---|---|---|
| 1 | `/access/users` | Usuario · Rol · Estado · Grupos · Crédito · Google · Gasto mensual · Gasto total · Creado · Acciones | 8 campos (`users_live.ex:89`) | search (nombre/email) + toggle «Gasto hoy» | ✅ `admin_pagination` 25/50/100 |
| 2 | `/access/services` | Servicio · Límite mensual · **Modelos** · **API Key** · Requests 30d · Gasto mensual · Gasto total · Creado · Acciones | 6 campos (`services_live.ex:23`) | search (nombre + texto del límite, incl. «ilimitado») | ❌ **ninguno** |
| 3 | `/access/groups` | **No es tabla** — cards: nombre · `N miembros · conc · RPM` · Gasto/mes · Crédito · `N modelos` · Acciones | — | search por nombre | ❌ |
| 4 | `/access/groups/:id/members` | Miembro · Límites · Modelos · Gasto/mes · Uso(tier) · Acciones | ❌ **ninguno** | search por miembro | ❌ |
| 5 | `/credit/topups` | Dueño · Monto · Consumo · Vence · Estado · Acciones | 5 campos (`topups_live.ex:32`) | search + toggle «archivados» | ❌ |

#### Stats (`/stats`, todas usan el MISMO mecanismo de paginado)

| # | Ruta | Columnas | Orden por |
|---|---|---|---|
| 6 | `/stats/users` | Usuario · **Grupos** · Requests · Costo · Tokens in · Tokens out · TPS · **Costo/req** · Crédito · ciclo | 6 campos |
| 7 | `/stats/services` | Servicio · Requests · Costo · Tokens in · Tokens out · **Cache %** · TPS · **Presupuesto · mes** | 6 campos |
| 8 | `/stats/groups` | Grupo · Requests · Costo · Tokens in/out · TPS · Costo/req · Presupuesto | 5 campos |
| 9 | `/stats/models` | Puesto · Modelo · Requests · Costo · Tokens in/out · Cache % · TPS · Costo/req | `model_name` + numéricos |
| 10 | `/stats/providers` | Puesto · Proveedor · Tier · Score · Requests · Fallos · Latencia · P95 · TTFT | — |

#### Catálogo y Operaciones (fuera del alcance de la paridad)

| # | Ruta | Columnas | Paginado |
|---|---|---|---|
| 11 | `/catalog/providers` | Alias · Key · En vuelo · Breaker | ❌ |
| 12 | `/catalog/models` | Proveedor · Modelo · Facturación · Prioridad · Scope · Estado · Acciones | ❌ |
| 13 | `/catalog/labs` | sin tabla | — |
| 14 | `/operations/monitoring` | ~20 cols: Fecha · Modelo · Tipo · Usuario · Grupo · Agente · API Key · Proveedor · Prov. Key · Prov. Status · Estado · Think · Effort · Streaming · Input · Output · Cache R · TPS · … | ✅ **cursor** `load_more`, `page_size 50` |

### 7.2 Paginado: hay **tres** mecanismos distintos y **cuatro** tablas sin ninguno

```
admin_pagination   → números de página, 25/50/100, in-memory   → SOLO /access/users
show_more          → carga incremental, per_page 10, in-memory → TODA la sección /stats
cursor/load_more   → cursor por inserted_at, page_size 50, DB   → SOLO /operations/monitoring
sin paginar        → services, group_members, topups, catálogo
```

`admin_pagination` (`admin_components.ex:249`) está **bien hecha**: rango
`1–25 de 31`, selector de tamaño, ventana `1 … n-1 n n+1 … última`, botones
deshabilitados en los extremos, `aria-current="page"`. Tiene tests reales
(`users_live_test.exs:621-659`). **Es la que hay que generalizar.**

### 7.3 🔴 El defecto grave del paginado

```elixir
# accounts.ex:123
def list_users(limit \\ 500) do
  Repo.all(from u in User, order_by: [desc: u.inserted_at], limit: ^limit)
end

# users_live.ex:94 — se llama SIN argumento
users = Accounts.list_users()
```

El paginador dice `1–25 de 31` pero está contando sobre una ventana de
**500 filas**. Con 501 usuarios: el 501.º **no aparece nunca** y el total
que muestra el paginador es falso. Pasar 501 usuarios no rompe por el
paginado — rompe por el `limit` hardcodeado de la capa de datos.

Segundo problema, menor: el orden en la query es `inserted_at DESC` pero
`sort_users` reordena **en memoria** por 8 campos. El `limit` de la query
corta un conjunto arbitrario y *después* se ordena → a partir de 500 filas
el orden es incorrecto, no solo incompleto.

`/access/services` no tiene este bug porque carga **todo** sin límite
(`from(s in Service, ...)` sin `limit`), a costa de no paginar.

**Regla a fijar: el paginado se hace en la DB, no en memoria.**
`UsersLive` es la excepción (in-memory) y es justo la que tiene el bug.
`MonitoringLive` ya lo hace bien (`cursor` + `limit` en la query, `monitoring_live.ex:493-519`) — es el patrón a copiar cuando la tabla crece.

### 7.4 Asimetría users ↔ services, columna por columna

| Columna | `/access/users` | `/access/services` | Veredicto |
|---|---|---|---|
| Identidad | ✅ | ✅ | ok |
| Estado | ✅ (Activo/Suspendido) | ❌ | **falta en services** (`Service` no tiene `status`; conviene añadirlo o usar «key activa/revocada») |
| Rol | ✅ admin/user | — | no aplica a servicios |
| Contenedor | ✅ Grupos | — | no aplica (el servicio no tiene) |
| Relación | ✅ Grupos | ❌ **Supervisores** | **falta** — el dato ya existe (`supervisors_map`, `services_live.ex:104`) y se muestra solo en el modal |
| Modelos | ❌ | ✅ (`N modelos`) | **falta en users** (solo el count aparece dentro de members) |
| API Key | ❌ (modal aparte) | ✅ | **falta en users** (la key cuelga del *miembro*, no del usuario → con P2 no aplica) |
| Límite mensual | ❌ (vive en «Crédito») | ✅ | **falta en users** como columna propia |
| Concurrencia/RPM | ❌ | ❌ | **falta en ambos** — hoy solo se ven en `/access/groups/:id/members` |
| Requests | ❌ | ✅ 30d | **falta en users** |
| Gasto mensual / total | ✅ | ✅ | ok |
| Grants «Google» | ✅ | — | no aplica |
| Paginado | ✅ | ❌ | **falta en services** |

### 7.5 Propuesta: una tabla de sujetos, dos lados

El objetivo no es «la misma tabla para usuarios y servicios» (son cosas
distintas) sino **la misma estructura de tabla**, con las columnas que
apliquen, en el mismo orden y con las mismas capacidades:

```
[ Identidad | Estado | Relación | Límites | Creditos | Modelos | Keys | Requests | Gasto mes | Gasto total | Creado | Acciones ]
      │         │         │          │         │         │        │
      │         │         │          │         │         │        └─ users: modal (N) │ services: modal (N, tras P2)
      │         │         │          │         │         └────────── users: — │ services: N modelos
      │         │         │          │         └──────────────────── users: N keys │ services: N keys (tras P2)
      │         │         │          └────────────────────────────── users: Crédito · ciclo │ services: Crédito · ciclo
      │         │         └───────────────────────────────────────── users: Grupos │ services: Supervisores
      │         └─────────────────────────────────────────────────── users: Activo/Suspendido │ services: nuevo `status`
      └───────────────────────────────────────────────────────────── users: nombre+email │ services: nombre
```

Cambios concretos:

1. **`Service.status`** (`active`/`suspended`) — simetría con `User` y
   `GroupMember`, que ya lo tienen (`user.ex:23`, `group_member.ex:18`). Hoy
   un servicio solo se puede «apagar» revocando la key.
2. **Columna «Supervisores»** en `/access/services` (el `supervisors_map` ya
   se carga y se tira). En users, «Grupos» ya está.
3. **Columna «Modelos»** en `/access/users` — el picker ya existe
   (`group_members_live.ex:716`), falta exponerlo desde la fila del usuario.
   *Bloqueado por P1/P2*: hoy el acceso a modelos es de la **membresía**, no
   del usuario.
4. **Columna «Límites»** (conc/RPM efectivos) en ambas tablas, con badge
   cuando es override propio. Requiere **P1**.
5. **`Requests 30d`** en users (services ya la tiene, `service_stats/2`).
6. **Generalizar `admin_pagination`** a: services, groups, group_members,
   topups. Y **arreglar el `limit: 500`** de `Accounts.list_users/1`.
7. **Unificar la etiqueta de crédito** a «Crédito · ciclo» en las 5 tablas
   de gestión y stats (hoy: «Crédito», «Crédito · ciclo», «Presupuesto · mes»,
   «Límite mensual», «Gasto/mes» — cinco nombres para el mismo número).

### 7.6 Decisión pendiente: un solo mecanismo de paginado

Recomendación: **`admin_pagination` + `limit`/`offset` en la query**, y
reservar el cursor para `monitoring` (volumen alto, orden por tiempo). El
`show_more` de `/stats` puede quedarse (es carga incremental de un ranking,
no navegación) pero debería usar el mismo `per_page` configurable.

El coste real de mover el paginado a la DB: `load_users/1` hoy ordena en
memoria por columnas calculadas (`credit`, `monthly_spend`, `total_spend`),
que exigen joins/agregados. Migrarlo es reescribir `sort_users` como
`order_by` de SQL — **es el trabajo más caro de P4** y conviene hacerlo
cuando se toque `request_logs.user_id` (idea extra de §5), porque ese join
es justo el que hoy se paga para el orden por gasto.


---

## 8. Hallazgo verificado: el CASCADE de `group_member_id` (pendiente de decisión)

`request_logs.group_member_id` referencia `group_members` con
**`ON DELETE CASCADE`**. Verificado con una transacción revertida: 1 fila de
log → `DELETE FROM group_members` → **0 filas**.

Consecuencia, y contradice lo que este plan prometía en §5: añadir
`request_logs.user_id` (W4, mergeado) **no** hace que «la historia del usuario
sobreviva al cambio de sub». `user_id` ya viaja en la fila y la agregación por
usuario ya no paga join, pero el FK borra la fila entera cuando se borra la
membresía — y cambiar de sub borra membresías
(`20260917011526_one_monthly_sub_per_user.exs`).

Igual que el `credit_subscription_id` del modelo viejo, la pregunta no es
técnica sino de semántica de datos. Opciones:

| Opción | Cambio | Efecto |
|---|---|---|
| A — referencia débil | `group_member_id` nullable + `ON DELETE SET NULL`; `user_id` dueño durable; `users` conserva su cascade | la historia del usuario **sobrevive** al cambio de sub; el log deja de decir a qué sub pertenecía |
| B — dejar el cascade | — | cambiar de sub borra historia; el log siempre dice a qué sub pertenecía |
| C — tercera vía | tabla de membresías histórica, o `group_member_id` como uuid crudo sin FK | conserva la atribución **y** la fila, a costa de una tabla o de perder integridad referencial |

**Recomendado: A**, con B como red de seguridad si la atribución por sub es
requisito de negocio. **No se decidió**: es un cambio de semántica de datos y
el usuario no respondió a tiempo. Queda como `?01` en el ledger, no
silenciado.
