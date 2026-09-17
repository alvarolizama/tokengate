# Homologación usuario ↔ servicio + rename «grupo» → «Perfil de límites»

Plan único que cubre las tres cosas pedidas:

1. **Homologar** la experiencia de Usuarios y Servicios — mismas columnas, mismas
   acciones, mismos modales, misma forma de revisar un sujeto y misma forma de
   configurarlo.
2. **Eliminar el concepto «grupo»** y renombrarlo a **Perfil de límites**, con
   URL nueva y rename completo hasta la DB.
3. **Configurar modelos desde el usuario**, con los del perfil **premarcados y
   bloqueados** (techo).

Fecha: 2026-09-16 · Base: `main` (rama con WIP sin commitear en LiveViews; este
plan no toca esos archivos hasta la fase que corresponda).

Reemplaza a `docs/paridad-usuario-servicio.md`, cuyas fases P1 y P3 **ya están
mergeadas** (`20260917033703_fold_member_extras_into_user.exs`, y
`Budgets.list_service_budgets/0` ya expone `has_credit?`/`credit_remaining_usd`).

---

## 0. Decisiones tomadas (fijadas por el usuario)

| # | Decisión | Consecuencia |
|---|---|---|
| D1 | Nombre: **Perfil de límites**. URLs `/budget/profiles` y `/budget/profiles/:id/members` | Rename de todo el vocabulario «grupo» |
| D2 | Los modelos del perfil, en el modal del usuario, van **premarcados y bloqueados** (TECHO) | Se activa `locked_ids`, hoy definido y nunca usado; el usuario solo **suma extras** |
| D3 | Rename **completo**: UI + módulos/campos + tablas y columnas en la DB | Migración calcada de `20260912202852_rename_teams_to_groups.exs` |

---

## 1. Punto de partida: qué ya es simétrico

No hay que rehacerlo. Lo asimétrico está en la **composición de las vistas**, no
en las piezas.

| Pieza | Estado | Evidencia |
|---|---|---|
| Cáscaras compartidas de UI | ✅ `admin_modal`, `admin_search`, `admin_identity`, `admin_empty_state`, `admin_delete_modal`, `admin_pagination`, `sort_button` | `components/admin_components.ex` (335 líneas) |
| Sujeto de gasto | ✅ `{:user, id} \| {:service, id}` | `credits.ex:101` |
| Semántica de nulos y límite efectivo | ✅ una sola regla `propio → contenedor → default` | `credits.ex:58-75`, `accounts.ex:1190+` |
| Enforcement (reserve/settle/release) | ✅ una sola máquina | `budgets/manager.ex:194-254` |
| Top-ups, API keys polimórficas | ✅ mismas tablas | `credits/topup.ex:97-108`, `api_key.ex:16-27` |
| Picker de modelos (3 estados) | ✅ con `granted/extra/denied/locked` | `core_components.ex:500-556` |
| Gasto mensual / total en ambas tablas | ✅ | `users_live.ex:1591-1610`, `services_live.ex:1140-1155` |

**Conclusión:** el motor ya es uno. Lo que falta es que las dos páginas se
compongan igual.

---

## 2. Rename «grupo» → «Perfil de límites»

### 2.1 Qué es la entidad (verificado en código)

`/budget/months` es `GroupsLive`. Su función real es **setear límites
heredables**, no un pozo de gasto:

| Qué define | Dónde |
|---|---|
| `default_concurrency_limit` / `default_rpm_limit` | `accounts/group.ex:15-16` |
| `monthly_spend_limit_usd` / `unlimited_spend` (techo mensual) | `accounts/group.ex:22-23` |
| Catálogo de modelos del contenedor (`group_models`) | modal `groups_live.ex:373-403` |
| Sus integrantes | `/budget/months/:id/members` (`GroupMembersLive`, 721 líneas) |

Dos hechos mandan sobre el nombre:

- `groups_live.ex:495-500` documenta que **el número no es un pozo común: cada
  miembro lo HEREDA**. La entidad es un paquete de límites + catálogo de
  modelos, no un presupuesto compartido.
- `20260917011526_one_monthly_sub_per_user.exs` fija **1 usuario = 1 perfil**
  (`unique_index(:group_members, [:user_id])`). Es una asignación, no una
  membresía múltiple.

### 2.2 Por qué «Perfil de límites» y no otro nombre

- «Presupuesto» ya nombra la sección del sidebar (`layouts.ex:319`) y el
  contexto `Tokengate.Budgets`.
- «Plan» ya está tomado por `Credits.plan/1` (`credits.ex:94-99`, `@type plan`),
  el plan de gasto de un sujeto. Dos «planes» en el mismo dominio sería peor que
  un nombre largo.
- «Límites» a secas está tomado por el limitador runtime ETS:
  `Tokengate.Limits.Manager` / `Tokengate.Limits.Supervisor`
  (`lib/tokengate/limits/`). Una tabla `limits` colisionaría conceptualmente.
- «Nivel»/«Tier» implica un ranking que no existe: los perfiles no están
  ordenados entre sí.
- «Perfil de límites» nombra la **función** y funciona como sustantivo al que
  *perteneces*. El único choque es `TokengateWeb.ProfileModal` — el modal de
  cuenta del usuario logueado (`live/profile_modal.ex`) — que **se renombra a
  `AccountModal`** (§2.5) porque «perfil de usuario» ≠ «perfil de límites».

### 2.3 Mapeo de identificadores

Nombres técnicos: se usa el prefijo `limit_profile` (no `profile` pelado) para
que un lector futuro no lea `Accounts.Profile` como «el perfil del usuario de
cuenta». El coste son nombres largos (`limit_profile_member_id`, 24 chars —
dentro del límite de 63 de Postgres y sin impacto en performance).

**Tablas**

| Hoy | Nuevo |
|---|---|
| `groups` | `limit_profiles` |
| `group_members` | `limit_profile_members` |
| `group_models` | `limit_profile_models` |
| `group_member_extra_models` | `limit_profile_member_extra_models` |
| `group_member_denied_models` | `limit_profile_member_denied_models` |

**Columnas**

| Hoy | Nuevo | Nota |
|---|---|---|
| `group_id` | `limit_profile_id` | 18 usos en DDL |
| `group_member_id` | `limit_profile_member_id` | 13 usos; FK a tabla **particionada** desde `request_logs` |
| `group_role` | *(drop)* o `member_role` | **huérfana**: sin campo en el schema `GroupMember` |
| `exclusive_to_group_id` | `exclusive_to_limit_profile_id` | `model_providers` |
| `exclusive_to_group_member_id` | `exclusive_to_limit_profile_member_id` | `model_providers` |

**Módulos Elixir**

| Hoy | Nuevo |
|---|---|
| `Tokengate.Accounts.Group` | `Tokengate.Accounts.LimitProfile` |
| `Tokengate.Accounts.GroupMember` | `Tokengate.Accounts.LimitProfileMember` |
| `Tokengate.Providers.GroupModel` | `Tokengate.Providers.LimitProfileModel` |
| `Tokengate.Providers.GroupMemberExtraModel` | `Tokengate.Providers.LimitProfileMemberExtraModel` |
| `Tokengate.Providers.GroupMemberDeniedModel` | `Tokengate.Providers.LimitProfileMemberDeniedModel` |
| `TokengateWeb.GroupsLive` | `TokengateWeb.LimitProfilesLive` |
| `TokengateWeb.GroupMembersLive` | `TokengateWeb.LimitProfileMembersLive` |
| `TokengateWeb.Stats.Groups` (`stats/groups.ex`) | `stats/limit_profiles.ex` |
| `TokengateWeb.ProfileModal` | `TokengateWeb.AccountModal` (limpia el nombre «perfil») |

Funciones del contexto a renombrar: `list_groups/0`, `change_group/2`,
`create_group_member/2`, `get_group_member/1`, `list_group_members_for_user/1`,
`sync_user_sub/2` (ya mezcla «sub»), `delete_group_member/1`,
`list_groups_by_user_ids/1`, `list_users_with_memberships/1`,
`invalidate_member_auth_cache/1`, y los `group_*` de `Budgets`
(`rollup_group_budgets/1`, `list_member_budgets/1`) y de `Providers`
(`grant_extra_model/2`, `deny_model/2`, `allow_model/2`, `revoke_extra_model/2`,
`list_accessible_models_for_member/1`).

### 2.4 Migración — receta del precedente

La migración se calca de `20260912202852_rename_teams_to_groups.exs`, que ya
hizo **este mismo ejercicio** (teams→groups) y dejó resuelto cada caso difícil:

1. `rename table(...), to: table(...)` para las 5 tablas.
2. `rename table(...), :group_id, to: :limit_profile_id` para las columnas.
   **`request_logs` es RANGE-particionada**: renombrar la columna del padre
   cascadea a todas las particiones (no se puede renombrar por partición).
3. **Renombrar los valores string almacenados** — esto es lo que se rompe en
   silencio si se omite:
   ```sql
   UPDATE budget_exemptions SET subject_type = 'limit_profile'
   WHERE subject_type = 'group';
   ```
4. **Recrear los 2 índices únicos parciales** de `budget_exemptions`, porque el
   valor viejo queda **dentro del predicado** del índice: un rename de tabla no
   lo actualiza y el índice deja de matchear filas.
   - `budget_exemptions_global_daily_group_unique` (predicado
     `scope='global_daily' AND subject_type='group' AND group_id IS NOT NULL`)
   - `budget_exemptions_user_daily_group_unique` (idem `user_daily`)
   - Renombrar a `_limit_profile_` **y** actualizar el literal del predicado.
   - Ojo: `20260913151502_purge_user_daily_exemptions.exs:22` también referencia
     `subject_type='group'` en un predicado.
5. **`subject_type` en el código**: `budgets/exemption.ex:28`
   (`"group" => :group_id`), `budgets/exemptions.ex:23,25,94`
   (`subject_label` → «Grupo: …»), `providers/model_provider.ex:374`,
   `models_live.ex:336,730`, `maintenance_live.ex:340` (option `"group"`).
6. **`rename_all_the_things/2`** del precedente (recorre `pg_constraint` e
   `pg_indexes` por fragmento, con la cadena de mapeo más larga primero, y salta
   los `_pkey` porque renombrar un PK renombra su índice). **Copiar tal cual**,
   parametrizado a `group → limit_profile` y `group_member → limit_profile_member`.
7. `down/0` completo y simétrico, como en el precedente.

### 2.4.1 🔴 El trigger de `request_logs` — el ítem más peligroso del rename

Verificado en `20260917033650_add_user_id_to_request_logs.exs:90-110`. Existe un
trigger **vivo en la DB** que referencia `group_members` y `group_member_id` por
nombre, en dos sitios distintos:

```sql
CREATE OR REPLACE FUNCTION request_logs_set_user_id() RETURNS trigger AS $$
BEGIN
  SELECT gm.user_id INTO NEW.user_id
    FROM group_members gm            -- ← tabla por nombre
   WHERE gm.id = NEW.group_member_id; -- ← columna por nombre
  RETURN NEW;
END;
$$ LANGUAGE plpgsql

CREATE TRIGGER request_logs_set_user_id_trg
  BEFORE INSERT ON request_logs
  FOR EACH ROW
  WHEN (NEW.user_id IS NULL AND NEW.group_member_id IS NOT NULL)  -- ← columna por nombre
  EXECUTE FUNCTION request_logs_set_user_id()
```

**Por qué es letal:** Postgres guarda el cuerpo de una función `plpgsql` como
**texto** y **NO lo reescribe** al renombrar tablas o columnas. Tras el rename:

- el `RENAME` de la tabla/columna pasa sin error (el cuerpo no se valida);
- el predicado `WHEN` del trigger referencia una columna ya inexistente →
  error al parsear;
- y al ser un **`BEFORE INSERT`**, el fallo se lleva por delante **toda
  escritura a `request_logs`** — el camino más caliente de la aplicación.

Y no aparece en ningún `grep` de `lib/`: vive solo en la base de datos. Es
exactamente el tipo de cosa que un rename «verde en los tests» deja rota en
producción.

**Mitigación obligatoria en la migración de rename**, en este orden:
1. `DROP TRIGGER request_logs_set_user_id_trg ON request_logs`
2. `DROP FUNCTION request_logs_set_user_id()`
3. renombrar tablas y columnas
4. **recrear** la función y el trigger con los nombres nuevos
   (`limit_profile_members`, `limit_profile_member_id`)

Como el trigger se crea en el **padre**, Postgres lo clona a cada partición
existente y `PartitionWorker` a las futuras — recrearlo en el padre basta.

Test de verificación que **debe** existir: insertar una fila en `request_logs`
sin `user_id` y comprobar que el trigger la rellena por join. Sin ese test, el
rename puede pasar el CI y romper el proxy.

**Nota de patrón** (del mismo archivo, útil para la migración nueva):
`@disable_ddl_transaction true` + `execute` **solo encola**; el backfill es un
`Repo.query!` y correría antes del DDL si no se llama `flush()` a mano
(`:112-119` documenta el porqué). El rename no necesita backfill, pero sí
respetar el orden de los `execute`.

### 2.4.2 Objetos de DB a inventariar antes de renombrar

Antes de escribir la migración, `\d+` sobre: `request_logs` (trigger + función),
los 2 índices únicos parciales de `budget_exemptions`, los índices de
`api_keys`/`request_metrics_hourly`/`observability_destinations`, y las
constraints de `model_providers`. El `rename_all_the_things/2` del precedente
cubre constraints e índices por fragmento, pero **no cubre cuerpos de funciones
plpgsql**: eso hay que hacerlo a mano (§2.4.1).

**Colisión conocida con la decisión abierta de §8** del doc viejo:
`request_logs.group_member_id` tiene `ON DELETE CASCADE`. Renombrar esa columna
es **la pasada barata** para cambiar además la semántica del FK (nullable +
`SET NULL`, con `user_id` como dueño durable): una sola migración sobre la tabla
más grande, en vez de dos. **Recomendado resolver ambos en el mismo cambio.**

### 2.5 Rutas y redirects

| Hoy | Nuevo |
|---|---|
| `/budget/months` | `/budget/profiles` |
| `/budget/months/:id/members` | `/budget/profiles/:id/members` |
| `/stats/groups` | `/stats/profiles` |
| `/stats/groups/:group_id` | `/stats/profiles/:group_id` |

Siguiendo la convención de `RedirectController`: `/budget/months[...rest]` y
`/stats/groups[...rest]` pasan a redirect permanente hacia el destino nuevo,
preservando subruta y query string (`append_rest/2` + `append_query/2` ya
existen). El redirect actual `/access/groups/*` → `budget_months`
(`router.ex:111-112`) se re-apunta al destino final.

**Bug a corregir en el mismo paso:** 3 links internos siguen apuntando a la URL
vieja `/access/groups` y solo funcionan por el redirect —
`group_members_live.ex:441` (botón «volver»), `groups_live.ex:454` y
`users_live.ex:1252`. Si se podan los redirects, esos tres rompen.

Sidebar: `layouts.ex:319-332` — sección `gettext("Budget")`, entrada
`gettext("Monthly budgets")` → «Perfiles de límites», y el comentario de
`layouts.ex:420` sobre el drill-down.

### 2.6 Trampa de entorno (verificada)

El reloj de esta máquina da `20260916231732`, **anterior** a la última migración
existente (`20260917033703_fold_member_extras_into_user.exs`).
`mix ecto.gen.migration` genera el timestamp desde el reloj, así que produciría
una migración que **ordena antes** de migraciones ya aplicadas. Antes de generar:
corregir el reloj, o fijar a mano un timestamp mayor que `20260917033703`.

---

## 3. Modelos por usuario (techo del perfil)

### 3.1 Estado real

- El picker de 3 estados **ya existe y ya soporta el premarcado**:
  `core_components.ex:517,534,542,545` define `locked_ids` → `badge-primary
  opacity-60` + `disabled` + tooltip «Otorgado por el grupo».
- **Ningún llamador lo pasa nunca.** Verificado: `locked_ids` solo aparece en su
  propia definición. Es capacidad muerta esperando exactamente este caso de uso.
- El picker **sí** se usa en: contenedor (`groups_live.ex:383-390`), miembro
  (`group_members_live.ex:690-700`), servicio (`services_live.ex:733-758`).
  **Falta solo a nivel usuario.**

### 3.2 El cambio (D2)

Acción **Modelos** en la fila de `/access/users` → modal con `<.model_picker>`:

| Prop | Valor |
|---|---|
| `models` | catálogo completo (`org_models`) |
| `locked_ids` | **los del perfil** → premarcados, bloqueados, no desmarcables (TECHO) |
| `extra_ids` | los que el usuario sumó por encima del perfil |
| `denied_ids` | hoy **no se usa** (un techo no se resta); el prop queda para servicios |
| `toggle_event` | `toggle_extra_model` |

**Sin tablas nuevas.** Como el usuario es 1:1 con su perfil, las tablas
`limit_profile_member_extra_models` / `..._denied_models` ya cuelgan del id
correcto (`list_accessible_models_for_member/1`, `providers.ex:1094`, ya
devuelve `{models, extra_ids, denied_ids}`).

Además: columna **«N modelos»** en `/access/users` (como ya tiene
`services_live.ex:1114-1125`), clickeable y abriendo el mismo modal.

Tooltip de `locked_ids` hay que reescribirlo: hoy dice «gestiónalo en Grupos»
(`core_components.ex:545`) → «Otorgado por tu perfil de límites».

---

## 4. Paridad de la tabla de gestión

Actual (verificado):

| | `/access/users` (`:1106-1184`) | `/access/services` (`:1001-1063`) | Veredicto |
|---|---|---|---|
| Identidad | avatar + nombre + email | icono + nombre + `conc · RPM` | mismo componente, subtítulo distinto |
| Estado | Rol + Estado | ❌ **no existe** | `services` no tiene columna `status` |
| Relación | Grupos | ❌ **Supervisores** | dato ya cargado (`services_live.ex:117`) y solo visible en el modal |
| Crédito | barra `$usado/$límite` (`:1535-1582`) | ❌ solo texto `limit_label` (`:1112`) | mismo número, dos renders, dos etiquetas |
| Modelos | ❌ | ✅ `N modelos` | falta en users (§3) |
| Claves | ❌ | ✅ `API Key` (1 sola) | users lo tiene en modal aparte |
| Requests 30d | ❌ | ✅ (`:1037`) | falta en users |
| Gasto mes / total | ✅ | ✅ | ya simétrico |
| Extra propio | Google (`:1153`) | — | asimetría correcta |
| Creado | ✅ | ✅ | ok |
| Paginado | ✅ (`:1206`) | ❌ | §6 |

**Orden objetivo (una sola estructura; los huecos se saltan, no se reordenan):**

```
Identidad · Estado · Relación · Límites (conc·RPM) · Crédito · ciclo · Modelos ·
Claves · Requests 30d · Gasto mes · Gasto total · [extra propio] · Creado · Acciones
```

1. `Service.status` (`active`/`suspended`) + migración. Simetría con `user.ex:23`
   y `group_member.ex:16`, que ya lo tienen. Hoy un servicio solo se «apaga»
   revocando la key. **Verificado: la migración inicial `20260729064718` añade
   `:status` a `service_api_keys`, no a `services`.**
2. Columna **Supervisores** en services (dato ya cargado, hoy se tira).
3. Columna **Requests 30d** en users.
4. **Modelos** y **Claves** como columna-count en ambas.
5. **Límites** (conc·RPM efectivos, badge si es propio) en ambas — hoy solo se
   ven en `/budget/months/:id/members`.
6. **Relación** en users: «Perfiles de límites» (hoy «Grupos», `:1139`) en
   singular, linkeable.

### 4.1 Acciones de fila: prefijo común + específicas

Defectos actuales, además de la falta de prefijo común:

- En users el **ojo** significa *impersonar* (`:1633-1643`) y en la columna
  Grupos significa *ver grupos* (`:1524`) — el mismo icono para dos cosas.
- `hero-key` se usa para **claves** (`:1631`) y para **reset de contraseña**
  (`:1658`) en la misma fila.
- Las acciones de users casi no llevan `title` (`:1644-1674`); las de services sí.

**Convención (D-actions):**

```
[ Ver detalle 👁 | Editar ✏ ]  → específicas  →  [ Eliminar 🗑 ]
```

- **Comunes al inicio**, mismo icono y mismo orden en ambas tablas.
- **Específicas en medio:**
  - users → *Modelos*, *Ver como*, *Restablecer contraseña*, *Suspender/Activar*
  - services → *Modelos*, *Claves*, *Supervisores*
- **Eliminar siempre al final**, vía el `admin_delete_modal` ya compartido.
- `title` + `aria-label` obligatorios en todas; iconos desambiguados
  (claves ≠ contraseña ≠ ojo).
- Servicios **gana** la acción *Suspender/Activar* cuando tenga `status`.

---

## 5. Modales, detalle y configuración

### 5.1 Un cuerpo por función

| Función | users hoy | services hoy | Target |
|---|---|---|---|
| Configurar | **2 modales** create (`:983-1024`) + edit (`:1026-1081`) + reset (`:1083-1102`) | **1 modal** (`:684-731`, título condicional) | `<.SubjectForm>` — uno, con `mode` |
| Claves | modal propio, N claves (`:1275-1405`) | dentro del detalle, 1 key reemplazada in-place (`:807-853`; `accounts.ex:897`) | `<.KeysPanel>` extraído del de users (decisión: superficie propia, en la fila) |
| Modelos | dentro de *Miembros* | modal propio (`:733-758`) | modal propio en ambas (§3) |
| Ver detalle | ❌ | modal (`:760-978`, 219 líneas) | quitar el modal → página (§5.2) |
| Eliminar | ✅ `:1407-1424` | ✅ `:980-996` | ya compartido ✔ |
| Token nuevo | alert dentro del modal (`:1311-1328`) | banner fuera (`:671-682`) | mismo lugar: dentro del modal de claves |

### 5.2 Revisar un sujeto: una página, un formato

**Decisión: la revisión individual es una PÁGINA**
(`/stats/users/:id` y `/stats/services/:id`), no un modal. El modal de detalle
de services (`services_live.ex:760-978`) se retira; su contenido útil (stats 30d,
claves, ruteo sticky, relación) se pliega en la página, que ya tiene casi todo.

`user_stats_live.ex` (722) y `service_stats_live.ex` (713) tienen **302 líneas
de deriva normalizada** y **una sola diferencia estructural**: la primera card
es *Membresías* (`user_stats_live.ex:427-453`) vs *Servicio*
(`service_stats_live.ex:409-433`). KPI strip (6 cards, ids y textos idénticos),
filtros (5 inputs idénticos) y tabla de logs (9 columnas idénticas) son **el
mismo markup**.

Objetivo: extraer `<.SubjectStats subject_kind={:user | :service} subject={…}
member_ids={…} back_path={…} back_label={…}>`:

- el filtro de logs cambia de `log.group_member_id in member_ids` a
  `log.service_id == id` según `subject_kind`;
- la primera card se parametriza;
- el resto queda **idéntico**;
- ~278 líneas de deriva → ~40 de adapter.

Y en esa página hay que corregir una etiqueta que hoy es falsa:
`service_stats_live.ex:424-429` dice **«Concurrencia extra» / «RPM extra»**
mientras `service.ex:8` documenta «son absolutos (no extras)».

`SupervisedServiceStatsLive` **no se toca** (asimetría intencional, §8), pero
puede consumir el mismo componente con `read_only: true`.

### 5.3 Configurar: un solo formulario

| | users create | users edit | services |
|---|---|---|---|
| nombre/email | ✅ | ✅ | ✅ |
| contraseña | ✅ | ❌ (modal aparte) | — |
| Rol | ✅ | ✅ | — (no aplica) |
| **Estado** | ❌ **falta** | ✅ | ❌ **no existe** |
| **Límite mensual + Ilimitado** | ❌ | ❌ | ✅ (`:697-710`) |
| **Concurrencia / RPM** | ❌ **falta** | ✅ (`:1050-1061`) | ✅ (`:713-724`) |
| Relación | `sub_id` (`:1011-1018`) | `sub_id` (`:1067-1075`) | supervisores (modal aparte) |

**Hallazgo, el más caro:** `users.monthly_spend_limit_usd` y
`users.unlimited_spend` **existen** (`user.ex:32-33`), están **validados**
(`user.ex:80,96,130`) y **se leen de verdad** en el camino caliente —
`Credits.user_limit/2` (`credits.ex:60-64`) los pone por delante del perfil —
pero **ninguna vista los escribe**:
`grep monthly_spend_limit_usd|unlimited_spend lib/tokengate_web/live/users_live.ex`
→ **0 coincidencias**. Un usuario puede quedar «ilimitado» o «topado a $X» solo
por DB/seeds, mientras el servicio sí lo configura desde la UI. Mismo campo, UI
en un lado, sin UI en el otro.

`<.SubjectForm>` con orden fijo: *Identidad → Estado → Crédito (límite +
ilimitado) → Límites (conc·RPM) → Relación → Credenciales*. Mismos hints
(tomar `services_live.ex:703,709` como texto canónico), mismo ancho, mismos ids
(`#user-form` / `#service-form`), mismo footer.

Ojo: `groups_live.ex:335` todavía dice «Cada miembro puede tener un extra que se
suma a este valor» — los `extra_*` **se eliminaron** en
`20260917033703_fold_member_extras_into_user.exs`. Hint obsoleto a corregir.

---

## 6. Transversal: paginado, filtros, etiquetas

- **Paginado: 3 mecanismos, 4 tablas sin ninguno.**
  ```
  admin_pagination → páginas 25/50/100, in-memory  → SOLO /access/users
  show_more        → incremental, per_page 10     → toda la sección /stats
  cursor/load_more → cursor por inserted_at, 50   → SOLO /operations/monitoring
  sin paginar      → services, group_members, topups, catálogo
  ```
  `admin_pagination` (`admin_components.ex:249`) está bien hecha y **tiene tests
  reales** (`users_live_test.exs:621-659`): es la que hay que generalizar a
  services / profiles / members / topups.

- **Bug de paginado a arreglar:**
  ```elixir
  # accounts.ex:123
  def list_users(limit \\ 500) do
    Repo.all(from u in User, order_by: [desc: u.inserted_at], limit: ^limit)
  end
  # users_live.ex:94 — se llama SIN argumento
  users = Accounts.list_users()
  ```
  El paginador dice «1–25 de 31» contando sobre una ventana de **500 filas**. Con
  501 usuarios, el 501.º no aparece nunca y el total es falso. Además el orden
  real se hace **en memoria** (`sort_users`, 8 campos) *después* del corte, así
  que a partir de 500 filas el orden es incorrecto, no solo incompleto.
  Regla a fijar: **el paginado se hace en la DB**. `MonitoringLive` ya lo hace
  bien (`monitoring_live.ex:493-519`) — es el patrón a copiar.

- **Filtros de header:** users tiene el toggle «Gasto hoy» (`:965-975`),
  services no. O ambos o ninguno.

- **Cinco nombres para el mismo número:** `Crédito` (users), `Límite mensual`
  (services), `Presupuesto · mes` (`stats/services.ex`), `Crédito · ciclo`
  (`stats/users.ex`), `Gasto/mes` (`group_members_live.ex:429`, y
  `groups_live.ex:429`). Unificar a **«Crédito · ciclo»** con el mismo tooltip.

- **Stats `/stats`, columnas cruzadas:** añadir `Cache %` a users y
  `Costo / req` a services (cada uno tiene lo que le falta al otro:
  `stats/users.ex:158`, `stats/services.ex:279-285`), y «Supervisores» como
  columna relacional de services.

- **Hints «grupo» sueltos** (`users_live.ex:1060,1254,1419,1529`;
  `group_members_live.ex:63,268,306,355,584,595`;
  `core_components.ex:545`; `dashboard_live.html.heex:91,150,162`;
  `monitoring_live.ex:953`; `maintenance_live.ex:340`;
  `models_live.ex:891,1063,1067,1081,1111,1713,1864,1885,1937`;
  `stats_live.html.heex:119`; `stats/groups.ex` (75 refs);
  `stats_export_controller.ex:245` `suffix = "_grupo"`) entran en el barrido.

---

## 7. Fases, dependencias y riesgo

```
F0 ──> F1 ──┬──> F2 ──> F3 ──> F4(perfiles) ──> F5(rename DB)
            ├──> F6 (modelos por usuario)
            └──> F7 (paginado en DB)
```

| Fase | Contenido | Depende | Riesgo | Motivo del riesgo |
|---|---|---|---|---|
| **F0** | Cerrar deriva: `Service.status` (migración). Decidir el `ON DELETE CASCADE` de `request_logs.group_member_id` | — | bajo | migración aditiva |
| **F1** | Columnas + labels + acciones (§4) | F0 | bajo | UI pura |
| **F2** | `SubjectForm` + `KeysPanel` (§5.1, §5.3) | F1 | medio | UI, sin lógica; toca 2 LiveViews grandes |
| **F3** | `SubjectStats` — página de revisión única (§5.2) | F2 | medio | fusiona 1.435 líneas en 2 archivos |
| **F4** | **Perfiles**: URLs, sidebar, redirects, textos, renombrar LiveViews y el vocabulario de UI (§2.5) | F1 | bajo | sin DB |
| **F5** | **Rename en DB + código** (§2.3, §2.4) — el grande | F4 | **alto** | 5 tablas, 5 columnas, valores string, 2 índices parciales, tabla particionada, **y el trigger plpgsql de §2.4.1** |
| **F6** | Modelos por usuario con techo del perfil (§3) | F1 | bajo | sin tablas nuevas; `locked_ids` ya existe |
| **F7** | Paginado en DB + `limit 500` (§6) | F1 | **alto** | `sort_users` ordena por columnas calculadas → reescribir como `order_by` SQL |

**F5 es el punto de riesgo único**, y su ítem más peligroso no es el rename de
tablas sino el **trigger `request_logs_set_user_id_trg`** (§2.4.1): su cuerpo
`plpgsql` guarda los nombres viejos como texto, Postgres no lo reescribe, y al
ser un `BEFORE INSERT` sobre la tabla más caliente un rename «verde en los
tests» puede dejar el proxy sin poder escribir un solo log. Los tres ratios a
favor: (a) el precedente `teams→groups` resolvió cada caso y está en el repo
para copiar; (b) **1727 ocurrencias en `lib/` y 1818 en `test/`, 41 de 86
archivos de test** — es mecánico y lo cubre la suite; (c) hacerlo junto con la
decisión de FK (§2.4) ahorra una pasada por `request_logs`.

**Gotcha de entorno (§2.6):** el reloj de la máquina precede a la última
migración. Corregir antes de `mix ecto.gen.migration` o fijar timestamp a mano.

---

## 8. Lo que NO se homologa (asimetría correcta)

- **El contenedor (perfil de límites) es solo de usuarios.** No se le inventa uno
  a los servicios, ni tres tablas de modelos a los usuarios.
- **Supervisores**: solo de servicios. `/services/supervised` da acceso read-only
  a un no-admin (`router.ex:131-135`); un servicio es infra compartida, un
  usuario es una persona.
- **`Google`**: solo de usuarios.
- **Rol / contraseña / impersonación**: solo de usuarios.

---

## 9. Archivos y tests afectados

**Producción (los grandes):**
`live/users_live.ex` (1692) · `live/services_live.ex` (1208) · `live/user_stats_live.ex` (722) ·
`live/service_stats_live.ex` (713) · `live/group_members_live.ex` (721) · `live/groups_live.ex` (525) ·
`components/admin_components.ex` (335) · `components/core_components.ex` (556) ·
`accounts.ex` (1400) · `providers.ex` · `budgets.ex` · `credits.ex` · `logs.ex` ·
`metrics/rollup.ex` (258 refs a `group`) · `routing/router.ex` (60) ·
`router.ex` · `redirect_controller.ex` · `layouts.ex` · `stats_export_controller.ex` ·
`providers/{group_model,group_member_extra_model,group_member_denied_model}.ex` ·
`accounts/{group,group_member}.ex` · `stats/groups.ex` (75) · `stats/{users,services}.ex` ·
`monitoring_live.ex` (53) · `stats_live.ex` (80) · `maintenance_live.ex` ·
`models_live.ex` (86) · `observability/otlp_builder.ex` (19) · `budgets/exemptions.ex` (19) ·
`live/profile_modal.ex` → `account_modal.ex`.

**Tests:** 41 de 86 archivos contienen `group`. Los que más cambian:
`users_live_test.exs` (854) · `services_live_test.exs` (205) ·
`user_stats_live_test.exs` (174) · `service_stats_live_test.exs` (130) ·
`stats_live_test.exs` (2032) · `groups_live_test.exs` · `group_members_live_test.exs` ·
`redirect_controller_test.exs` · `accounts_test.exs` · `providers_test.exs` ·
`budgets_test.exs` · `api_key_cache_test.exs` · `sort_header_align_test.exs` ·
`sidebar_test.exs` · `budget_labels_test.exs`.

**Migraciones:** 19 archivos de migración referencian `group`. Solo se tocan con
una migración nueva (las aplicadas no se editan).

---

## 10. Verificación

Cada fase cierra con `mix precommit` (alias del proyecto, exigido por AGENTS.md).

Tests que **deben** existir al terminar, uno por invariante nueva:

| Fase | Test |
|---|---|
| F1 | `Service.status` cambia y la tabla de services muestra el badge; la columna Supervisores lista los supervisores |
| F2 | Un solo modal de form con los mismos campos e ids en ambas páginas |
| F3 | Mismos KPI ids, mismos filtros y mismas columnas de logs en `/stats/users/:id` y `/stats/services/:id` |
| F4 | Cada URL vieja (`/budget/months`, `/access/groups`, `/stats/groups`) responde 301 al destino nuevo **preservando subruta y query string** |
| F5 | `mix ecto.rollback && mix ecto.migrate` limpio; los 2 índices parciales de `budget_exemptions` siguen siendo únicos y matchean filas nuevas; `subject_type='limit_profile'` matchea; **insertar en `request_logs` sin `user_id` y comprobar que el trigger de §2.4.1 la rellena por join sobre la tabla renombrada** |
| F6 | Modelos del perfil llegan como `locked` (`disabled`) en el modal del usuario; el extra se guarda y el modelo del perfil **no** se puede quitar |
| F7 | Con 501 usuarios, el 501.º es alcanzable y el total del paginador es el real |

Regresión crítica de F5 (heredada del doc viejo): editar el perfil debe seguir
invalidando el cache de auth del miembro (`api_key_cache.ex:28-42` documenta el
contrato); el gemelo de `api_key_cache_test.exs:107` para editar el **usuario**
es obligatorio si F5 toca `effective_limits`.

---

## 11. Cierre

Con D1+D2+D3 aplicadas, las dos páginas quedan con la **misma estructura de
tabla**, el **mismo prefijo de acciones**, los **mismos modales** (`SubjectForm`,
`KeysPanel`, `Modelos`), **una sola página de revisión** alimentada por
`<.SubjectStats>`, y el contenedor deja de llamarse «grupo» en la UI, en el
código y en la base de datos.

Lo que **no** cambia es a propósito: el proxy y el enforcement. Renombrar
`request_logs.group_member_id` es un `ALTER TABLE`, no un cambio de lógica; el
cache de auth sigue resolviendo por hash de token (`accounts.ex:1229`), y el
limitador ETS (`Tokengate.Limits`) no se toca.

---

## 12. Estado de ejecución y correcciones verificadas

Ejecutado en 5 olas sobre worktrees aislados. Cada rama se verificó de forma
independiente antes de integrar (no se aceptó el auto-reporte de ningún agente).

### 12.1 Rama de integración

`wt/integracion` (commit `cbe253b`) = checkpoint `b132e30` + olas 1. `main`
sigue en `a45f158` y el árbol de trabajo del usuario quedó intacto; el WIP
original está preservado en `b132e30` (rama `wip/checkpoint-homologacion`).

| Rama | Fase | Commit | Tests reales | Estado |
|---|---|---|---|---|
| `wt/th1` | F0 `Service.status` | `0fca26f` | 10 + 62 + 137 | ✅ integrada |
| `wt/th2` | F3 `SubjectStats` | `a669c1d` | 13 | ✅ integrada |
| `wt/th6` | F7 paginado en DB | `3d06263` | 8 + 99 + 42 | ✅ integrada |
| `wt/th3` | F4a rutas | `1579970` | 39 | ✅ integrada |
| `wt/th4` | F4b textos | `d37f84a` | 35 + 404 | ✅ integrada |
| `wt/th5` | F5 migración de DB | `7ac9190` | 8 | ⏸️ **retenida a propósito** |

**Suite completa verificada tras integrar la ola 1** (no solo los tests
tocados): `MIX_ENV=test MIX_TEST_PARTITION=7 mix test` → **1480 passed, 0
failures** en 307.7s. Baseline de la misma máquina antes de la ola 1:
**1453 passed, 0 failures** en 315.1s. Es decir **+27 tests nuevos y cero
regresiones**. Los `[error] Postgrex.Protocol ... disconnected` del log son
ruido del sandbox al morir un owner, no fallos: el resultado dice 0 failures.

`wt/th5` **no se integra todavía**: su migración renombra las tablas y rompe la
aplicación entera hasta que aterrice el rename de código (F5-código). Dejarla en
el árbol con migraciones pendientes es una mina: cualquier `mix ecto.migrate`
posterior la aplicaría y tiraría la app. Se integra EN LA MISMA OLA que el
rename de código.

### 12.2 Correcciones a este documento (verificadas contra la DB y el código)

1. **§2.4.1 — mi diagnóstico era parcialmente incorrecto.** El predicado `WHEN`
   del trigger **no** se rompe: Postgres lo guarda como `pg_node_tree` con
   *attnums*, no con nombres, y se re-renderiza solo tras el rename. Lo que se
   rompe es el **cuerpo `plpgsql`**, que sí es texto. Verificado reproduciendo el
   error (`ERROR: record "new" has no field "group_member_id"`) con el rename
   ingenuo en una transacción revertida. La mitigación (dropear función y
   trigger, renombrar, recrear) sigue siendo obligatoria — pero por el cuerpo,
   no por el predicado.
2. **`group_members.group_role` ya no existe**: lo dropeó
   `20260912213521:67`. No hay columna muerta que limpiar; inventar
   `member_role` habría añadido una.
3. **Solo UN índice único parcial** lleva el literal `'group'`
   (`budget_exemptions_global_daily_*`); el de `user_daily` lo purgó
   `20260913151502`. La migración los trata condicionalmente para no resucitarlo.
4. **`services.group_id` es una isla legacy y NO se renombra** — corrección a
   §2.3. La desacopló `20260914044359` pero quedó la columna, con FK
   `services_group_id_fkey → groups(id)`, sin campo en el schema
   `Service`. La leen y escriben por SQL crudo un **test congelado**
   (`test/tokengate/accounts_test.exs:142-165`) y `accounts.ex:66`; el nombre del
   constraint se cita en `accounts.ex:95`. Renombrarla rompería ambos por
   nombre. El *walker* genérico excluye `services`.
5. **Orden obligatorio: columnas ANTES que tablas**, con guardas `IF EXISTS` que
   leen el nombre vivo de la tabla. Renombrar las tablas primero hacía que los
   renames de columna se saltaran **en silencio** (lo detectó el diff de
   inventario, no un test).
6. **6 identificadores no vuelven byte a byte** tras el `down`: `limit_profile`
   es 5 bytes más largo que `group` por aparición y Postgres trunca a 63 bytes.
   Mismo OID y misma definición, rótulo más corto. Medido y listado.
7. **§2.5 — los redirects son 302, no 301.** `RedirectController` usa
   `redirect/2` sin `status`, y ese es su comportamiento histórico para toda
   página movida. Convertirlo a 301 real exige tocar todo el controlador. Si se
   quiere 301, es una decisión aparte, no un detalle de esta fase.

### 12.3 Hallazgo nuevo, no previsto en el plan: el enforcement de suspensión

`services.status` **no suspende nada por sí solo**. En
`lib/tokengate_web/plugs/api_auth.ex`:

- `service_to_virtual_member/1` hardcodea `status: "active"` en el `GroupMember`
  virtual;
- `active_membership/1` es quien decide `:ok | :inactive` y lee ese mismo campo.

Consecuencia: un servicio marcado `suspended` **sigue autenticando y sirviendo
tráfico**. La columna es informativa. F0 no queda cerrada con la migración: hace
falta copiar `service.status` al miembro virtual **y** verificar si el cache de
auth (`api_key_cache.ex`) exige invalidación al cambiar el status. Es lo que
hace la ola 2.

### 12.4 Verificación independiente de las olas 1 y 2

Ningún entregable se aceptó por auto-reporte. Comprobado a mano:

**Paridad de columnas (w8)** — extraídas las etiquetas `<th>` reales de las dos
tablas y normalizados los tres pares legítimamente distintos (columna de
identidad, `Rol`↔`Estado`, `Perfiles de límites`↔`Supervisores`), las dos
secuencias quedan idénticas:

```
USERS   : Identidad · Rol · Perfiles de límites · Límites · Crédito · ciclo · Modelos · Claves · Requests 30d · Google · Gasto mensual · Gasto total · Creado · acciones
SERVICES: Identidad · Estado · Supervisores        · Límites · Crédito · ciclo · Modelos · Claves · Requests 30d ·        Gasto mensual · Gasto total · Creado · acciones
```

`Google` es la única columna exclusiva de users — exactamente la asimetría
correcta (§8).

**Acciones de fila** — el orden está impuesto ESTRUCTURALMENTE por
`AdminRowActions` (`detalle → editar → {render_slot(@specific)} → eliminar`), no
por convención escrita: las dos tablas lo consumen
(`users_live.ex:1716-1768`, `services_live.ex:1320-1349`), así que no puede
volver a derivar. Iconos desambiguados: `hero-eye` es sólo «Ver detalle»,
`hero-identification` impersonar, `hero-arrow-path` contraseña, `hero-lock-*`
estado. El defecto original (el mismo `hero-key` para claves y para reset de
contraseña en la misma fila) está muerto.

**Enforcement de suspensión (w9)** — cadena verificada a mano:
`service_to_virtual_member/1` copia `service.status`; `build_auth_entry/1`
(`accounts.ex:1667`) es su único consumidor; `active_membership/1` decide sobre
ese campo. `update_service/2` (`accounts.ex:1203`) termina en
`invalidate_member_auth_cache(service.id)` → **suspensión inmediata, sin TTL**.
Resultado exacto: **403** con cuerpo
`{"error":{"code":"membership_inactive","message":"Group membership is not active","type":"authentication_error"}}`
— idéntico al rechazo de un usuario suspendido, sin revocar la API key. El test
del agente es **rojo sin el fix** (comprobado con `git stash` del archivo: el
servicio suspendido recibía 200). TTL del cache: 60 s (`api_key_cache.ex:57`),
que sólo aplica si alguien escribe el status saltándose `update_service/2`.

**Flakiness de la suite:** primera corrida completa de la ola 2 → 1508/1510 con
2 fallos; con `--seed 0` → **1510/1510**. Son fallos DEPENDIENTES DEL ORDEN, no
regresiones. Los sospechosos por diseño son los tests nuevos que manipulan el
cache ETS global de auth. Caracterización con varios seeds en curso.

### 12.5 Medición del alcance de F5 (el rename) y deuda abierta

**Superficie real del rename**, medida sobre la integración actual (no estimada):
**1752** identificadores `group*` en `lib/` y **1924** en `test/` → **3676
ocurrencias**, en **44 de 89** archivos de test. Los archivos más cargados:
`metrics/rollup.ex` (245), `accounts.ex` (152), `providers.ex` (130),
`groups_live.ex` (112), `models_live.ex` (83), `stats_live.ex` (80),
`logs.ex` (80), `stats/groups.ex` (72).

**F5 es atómico y por tanto serial**: no se puede partir en «capa de datos» y
«capa web» porque `lib/tokengate_web` referencia módulos de `lib/tokengate`; un
rename a medias no compila. Y no puede correr en paralelo con F2 porque ambos
tocan `users_live.ex` / `services_live.ex`. Va último, en solitario, con la
migración de `wt/th5` integrada en el mismo cambio.

**Deuda de formato encontrada y corregida**: `w8` y `w10` dejaron 5 archivos sin
formatear (`admin_components.ex`, `services_live.ex`, `users_live.ex` y los dos
tests de LiveView). `mix precommit` incluye `format`, así que rompía el alias
exigido por AGENTS.md. Corregido en `aa26e82`; `mix format --check-formatted`
sale limpio.

**🔴 Dos causas de fallo intermitente, y una es un defecto real de la suite.**

**Causa 1 — `ProxyControllerTest` bindea un puerto FIJO.** Verificado:
`test/tokengate_web/controllers/proxy_controller_test.exs:20` declara
`@port 41236` y la línea 288 lo usa en `start_supervised!({Bandit, ..., port:
@port})`. El puerto **no se deriva de `MIX_TEST_PARTITION`**, así que **dos
`mix test` concurrentes colisionan siempre** con `:eaddrinuse`, y el fallo
aparece como 10 tests en rojo (todo el `describe` que comparte ese setup), no
como un error de entorno evidente.

Consecuencia que va más allá de este trabajo: el proyecto **soporta** particiones
de CI (`config/test.exs` usa `tokengate_test#{System.get_env("MIX_TEST_PARTITION")}`),
pero con el puerto fijo **una CI particionada fallaría**. Es un defecto
preexistente de la suite, no introducido por ninguna ola. Arreglo mínimo:
`@port String.to_integer(System.get_env("MIX_TEST_PORT") || "41236")` o derivarlo
del `MIX_TEST_PARTITION`.

Esto **invalida fallos intermitentes observados antes** por mi culpa y no por el
código: la primera corrida completa de la ola 2 dio 1508/1510 y los 2 fallos
coincidieron con agentes (`w10`, `w11`) corriendo sus propias suites en
paralelo. Lo mismo con los 1518/1528 posteriores. **Una corrida autoritativa
exige la máquina en solitario.**

**Causa 2 — DESCARTADA: era contaminación mía.** Hubo un segundo fallo, una
sola vez, que atribuí a que un test de `w8` asumía la página 1:

```
test "la columna Modelos cuenta los del perfil y abre el modal"
     (TokengateWeb.UsersLiveTest)
```

**Ese diagnóstico era especulación mía y es falso.** Dos comprobaciones lo
desmienten:

1. Estático: el test crea **2 usuarios** (`register("admin")` + `register("user")`)
   y el `per_page` por defecto es 25, así que ambos caen en la página 1 con
   cualquier orden. No hay dependencia de página que valga. Además
   `load_models_count/1` recibe las membresías de los usuarios de la página, así
   que el conteo viaja con la fila.
2. De proceso: ese fallo ocurrió en una corrida donde **yo mergeé `w10` en
   `/tmp/th-int` mientras la suite corría**. `w10` reescribió precisamente el
   modal de modelos que ese test ejercita. La suite corrió contra un árbol a
   medio cambiar.

O sea: **no hay evidencia de un flake real en el código**. Las dos
observaciones de fallo intermitente tienen explicación inocente — puerto fijo
(concurrencia) y mi propia contaminación. Queda pendiente **una corrida
autoritativa con la máquina en solitario** para fijarlo por escrito; hasta
entonces no se afirma que la suite sea verde de forma estable.

### 12.6 Invariantes que la suite ya no cubría y ahora sí

`load-more-*-stats-logs` y los eventos de filtro de las dos páginas de detalle
**no** estaban cubiertos por los tests del repo (los cubrió un arnés desechable
durante F3). Con F3 fusionado conviene añadirlos a los dos archivos de test.

