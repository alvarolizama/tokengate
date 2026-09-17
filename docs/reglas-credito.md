# Reglas del modelo de crédito — verificación

Reglas enunciadas (2026-09-17, `main`), con su vocabulario:

1. Un usuario **sin sub** no tiene crédito ni presupuesto.
2. El **ilimitado** solo se consigue si se agrega a un **grupo ilimitado**.
3. Un usuario **sin grupo**, solo con **top-up**, puede tener crédito.

Vocabulario en la app: **sub** = `group` (la membresía, `group_members`);
**presupuesto** = `*_spend_limit_usd` (límite mensual, ciclo = mes calendario
UTC); **crédito** = saldo de **top-up**.

## Estado verificado

| # | Regla | Hoy | Evidencia |
|---|---|---|---|
| 1 | sin sub ⇒ sin presupuesto | **✗ el motor sí acepta límite propio** | `Credits.user_limit(user, nil)` → `%{source: :user, limit_usd: Decimal("100.00")}` |
| 2 | ilimitado solo vía grupo ilimitado | **✗ el motor acepta `users.unlimited_spend`** | `Credits.user_limit(user, nil)` → `%{source: :user, unlimited?: true}`. Lo fija `test/tokengate/credits/plan_test.exs:159` («unlimited_spend propio gana sobre el límite del grupo») |
| 3 | sin presupuesto + top-up ⇒ puede tener crédito | **✗ su key no autentica (401)** | `Accounts.resolve_auth_by_api_key(token)` → `:error`: la key es del `user_id`, pero `Accounts.member_for_key/2` (`lib/tokengate/accounts.ex:611-623`) exige resolver un `GroupMember`, y `Credits.plan/1` solo se arma desde una membresía. El motor sí le da crédito; lo que falla es la autenticación |

Contrastes que sí cumplen:

- usuario **en** un grupo ilimitado hereda ilimitado → `%{source: :group, unlimited?: true}`;
- usuario **en** un grupo sin límite + top-up → plan `%{limit_usd: nil, unlimited?: false, topups: [una]}`.

O sea: «solo con top-up» funciona **dentro** de un grupo; la regla 3 (sin grupo)
es la que no tiene camino.

`test/tokengate/rules_probe_test.exs` es el probe temporal que produjo estas
líneas (5 tests, verdes: fijan el comportamiento **actual**, no las reglas).

## Matices

- **La UI sí respeta las reglas 1 y 2.** El form de usuario
  (`users_live.ex:1006-1045`) expone solo conc/RPM propios + «Sub mensual»; los
  inputs de límite/ilimitado existen únicamente en grupos (`groups_live.ex:344,352`)
  y servicios (`services_live.ex:698,706`). La deriva vive en el motor
  (`credits.ex:58-75`) y en la API de cuentas (`User.@spend_fields`), alcanzable
  por DB/seeds/tests.
- **La UI sí deja crear keys a un usuario sin sub** («Claves» en
  `users_live.ex:432-449`, `subject_type: "member"` + `user_id`), y esa key
  siempre da 401. Es la contradicción más concreta de la regla 3.
- **Datos**: la migración vieja `20260916193827_drop_credit_subscriptions`
  (@user_unlimited) marcó `unlimited_spend = true` a usuarios sin grupo. En dev:
  2 usuarios sin grupo y ambos ilimitados (`nekrox@gmail.com`,
  `smoke-admin@example.com`, 0 keys y 0 requests ⇒ limpiarlos no corta tráfico),
  `alvaro@example.com` ilimitado por grupo **y** por flag propio (redundante) y
  `sofia@demo.tokengate` con límite propio 30 sobre el 200 del grupo.
- **Contradicción de documentación**: `docs/paridad-usuario-servicio.md:143`
  define el gasto como `propio || contenedor || default` con
  `users.monthly_spend_limit_usd` como primer nivel — lo contrario de la regla 1.

## Qué significa «sin límite» (usuarios vs servicios)

El motor tiene **tres** estados (`Credits.user_limit/2` / `service_limit/1`,
`lib/tokengate/credits.ex:58-84`), y la UI usa **dos** palabras para ellos:

| estado | UI dice | significado real |
|---|---|---|
| `unlimited_spend = true` | «Ilimitado» / «Crédito ilimitado» | salta la capa del sujeto: no lo topan ni su límite ni sus top-ups, **solo el cap global diario** |
| `*_spend_limit_usd IS NULL` | «Sin límite» | **no hay límite**: solo drena top-ups; sin top-up vigente = **402 `:no_credit`** (bloqueado) |
| `*_spend_limit_usd = 0` | `$0.00/mes` | **CERO**, jamás ilimitado: solo top-ups; sin top-up = 402 `:subject` |
| `*_spend_limit_usd > 0` | `$X/mes` | límite del ciclo (mes calendario UTC) |

Es decir: **«sin límite» es lo contrario de «ilimitado»** — significa «sin
presupuesto». El único camino a ilimitado es `unlimited_spend`.

### Matriz medida (`test/tokengate/sin_limite_probe_test.exs`, request de $0.01)

Usuario (`limit=`, `unlimited?`, `topups`, `has_path?` → resultado sin cap global):

| caso | limit | unl | topups | has_path? | resultado |
|---|---|---|---|---|---|
| SIN sub, sin nada | nil | false | 0 | false | **402 no_credit** |
| SIN sub + top-up 10 | nil | false | 1 | true | OK (topup) |
| SIN sub + unlimited propio | nil | true | 0 | true | OK (salta el sujeto) |
| SIN sub + límite propio 100 | 100.00 | false | 0 | true | OK (limit) |
| sub SIN límite (nil), sin top-up | nil | false | 0 | false | **402 no_credit** |
| sub SIN límite (nil) + top-up 10 | nil | false | 1 | true | OK (topup) |
| sub límite 0, sin top-up | 0.00 | false | 0 | false | **402 subject** |
| sub límite 0 + top-up 10 | 0.00 | false | 1 | **false** | OK (topup) ⚠️ |
| sub límite 50, sin top-up | 50.00 | false | 0 | true | OK (limit) |
| sub límite 50 AGOTADO, sin top-up | 50.00 | false | 0 | false | **402 subject** |
| sub límite 50 AGOTADO + top-up 10 | 50.00 | false | 1 | **false** | OK (topup) ⚠️ |
| sub ilimitada (heredada) | nil | true | 0 | true | OK (salta el sujeto) |
| sub ilimitada + top-up 10 | nil | true | 1 | true | OK (salta el sujeto) |

Servicio: `SIN límite sin top-up` → 402 no_credit; `+ top-up` → OK (topup);
`límite 0` → 402 subject; `límite 0 + top-up` → OK (topup); `ilimitado propio`
→ OK (salta el sujeto); `límite 50` → OK (limit).

### Usuario vs servicio: la única diferencia es de dónde sale el número

| | `nil` significa | contenedor |
|---|---|---|
| Usuario | sin límite **propio** → hereda el de su sub | la sub (grupo) |
| Servicio | sin límite, punto | ninguno |

El **comportamiento** es idéntico (la columna de servicio de la matriz es la de
un usuario cuya sub tenga el mismo valor). Lo que cambia es la resolución:
`user_limit/2` mira `usuario → sub → ninguno`; `service_limit/1` mira solo el
servicio.

### «Ilimitado» tampoco es «sin techo»

Medido: con el cap global diario en `0`, un sujeto `unlimited_spend` **sí**
recibe `402 :global` (capa 2 del modelo, `GlobalSettings.daily_max_spend_usd`,
`lib/tokengate/global_settings.ex:6-13`). La única forma de saltarlo es una
**exención** (`budget_exemptions`, por usuario o por grupo:
`Budgets.Exemptions.exempt?/3`, `lib/tokengate/budgets/exemptions.ex:34-41`).

### ⚠️ Defecto medido: `has_path?` marca «bloqueado» a quien sí puede gastar

`Credits.has_path?/3` (`lib/tokengate/credits.ex:292-298`) ignora los top-ups
cuando existe un límite:

```elixir
def has_path?(false, %Decimal{} = limit, _topup), do: Decimal.compare(limit, 0) == :gt
def has_path?(false, nil, %Decimal{} = topup), do: Decimal.compare(topup, 0) == :gt
```

Con límite `0` (o agotado) + top-up vigente devuelve `false`, pero el motor
**sí** drena el top-up (las dos filas ⚠️ de la matriz). `has_path?` es la
entrada de `exhausted?` en `Budgets.list_service_budgets/0`
(`budgets.ex:116`), de `monthly_exhausted?`/`exhausted?` en `member_budget/3`
(`budgets.ex:406-407`) y del listado de mantenimiento
`Credits.blocked_users/0` (`credits.ex:413`): esas vistas reportan como
«agotados» sujetos que tienen crédito de top-up.

## Cómo se configura un usuario ilimitado (por la UI)

Verificado de punta a punta con el camino real de las LiveViews
(`test/tokengate_web/live/budget_labels_test.exs`):

1. **`/budget/months`** (antes `/access/groups`) → botón **Editar** del
   presupuesto mensual → campos **«Límite mensual (USD)»**
   (`group[monthly_spend_limit_usd]`) y checkbox **«Ilimitado»**
   (`group[unlimited_spend]`) → **Guardar**. El hint del propio form declara la regla: «Único camino a
   ilimitado; gana sobre el límite».
2. **`/access/users`** → **Editar** del usuario → select **«Presupuesto
   mensual»** (`user[sub_id]`) → el que está ilimitado → **Guardar**
   (`save_edit_user` → `Accounts.sync_user_sub/2`).

Resultado medido: `Credits.user_limit/2` → `%{source: :group, unlimited?: true}`
y la tabla de usuarios pinta el badge **«Ilimitado»** (tooltip «Marcado
ilimitado: solo topa el cap global diario»).

### Es el único camino **de la UI**, pero el motor tiene otro

El form de usuario no tiene ningún campo de gasto: `refute html =~
"user[unlimited_spend]"` y `refute html =~ "user[monthly_spend_limit_usd]"`
(solo nombre, rol, estado, conc/RPM y sub). O sea, **la UI sí cumple la regla
2**; lo que no la cumple es el motor, que sigue honrando
`users.unlimited_spend` (y `users.monthly_spend_limit_usd`) como primer
eslabón — alcanzable hoy solo por DB/seeds/tests, no por pantalla.

### Vocabulario y rutas

Con el renombre, la sección del sidebar es **Presupuesto** (`/budget/*`):
`/budget/months` (presupuestos mensuales) y `/budget/topups`. Las etiquetas
visibles salen de **gettext** con msgid en inglés y traducción en
`priv/gettext/es/LC_MESSAGES/default.po` (`Budget` → «Presupuesto»,
`Monthly budgets` → «Presupuestos mensuales», `Monthly budget` →
«Presupuesto mensual», `No budget` → «Sin presupuesto»); el locale por defecto
es `es`. Las rutas viejas redirigen (`/access/groups*` → `/budget/months*`,
`/credit/topups*` → `/budget/topups*`).

### Dos desviaciones de visualización, medidas

1. **La columna de presupuesto miente hasta 5s después de un cambio.** `users_credit`
   se guarda en `Metrics.DashboardCache` bajo `{:users_credit_by_user, ids}`
   con TTL 5s (`users_live.ex:128-132`) y **nadie invalida** esa entrada al
   editar la sub o el usuario (`DashboardCache.invalidate_all/0` no tiene
   llamadores). Medido: tras darle la sub ilimitada, el mismo LiveView sigue
   mostrando «Sin límite»; con `DashboardCache.invalidate_all/0` + remount,
   «Ilimitado». El motor nunca estuvo desalineado — solo la tabla.
2. **Un usuario sin presupuesto mensual salía siempre «Sin límite»**, aunque su
   flag propio dijera ilimitado: `load_users_credit/1` devolvía un mapa fijo
   cuando `memberships == []`, sin mirar `user.unlimited_spend` ni
   `user.monthly_spend_limit_usd`. **Arreglado**: el branch sin membresía ahora
   resuelve el sujeto contra el propio usuario (`Credits.user_limit/2`) y lee
   sus top-ups en lote, así que la columna refleja el estado real.

(1) y (2) van en direcciones opuestas: una muestra viejo a quien cambió, la
otra nunca muestra el flag propio. Las dos nacen de que la columna se resuelve
por **membresía**, no por sujeto.

## Decisiones pendientes


1. **Regla 3**: ¿cerrar la brecha (membresía virtual para usuarios sin sub, como
   ya se hace con los servicios, para que su key autentique y drene el top-up),
   bloquearla en la UI (sin sub no se crean keys) o dejar solo documentada la brecha?
2. **Reglas 1 y 2**: ¿la sub pasa a ser la única fuente de gasto del usuario
   (quitar los caminos propios en `Credits.user_limit/2`, ajustar
   `plan_test.exs:159` y limpiar el flag en datos) o el override propio se
   mantiene como nivel válido y solo se documenta que la UI no lo expone?
