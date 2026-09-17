# Alta de modelos guiada por el catálogo de models.dev

**Estado: implementado (F1+F2+F3) el 2026-09-17.** Migración
`20260917063837_catalog_models.exs`, mirror de modelos + ofertas, picker en
ModelosLive, proveedor→API key en el mismo modal, y snapshot vendorizado. Ver
§9 para lo que cambió respecto al plan.

Plan para: (1) crear modelos con la metadata de models.dev por default, con un
**buscador igual al de proveedores**; (2) elegir **proveedor + su API key** (y lo
que la key necesite) en el mismo flujo; (3) **agregar más API keys** a un modelo
ya dado de alta mejorando el modal actual; (4) seguir pudiendo crear **modelos
custom a mano**.

Fecha: 2026-09-17 · Base: `main` (hay WIP sin commitear en `maintenance_live`,
`global_cap_live`, `router.ex`; este plan **no toca** esos archivos salvo
`maintenance_live` para los contadores del catálogo).

---

## 0. Decisiones propuestas (recomendadas; confirmar en §8)

| # | Decisión | Consecuencia |
|---|---|---|
| D1 | El espejo cubre **solo ofertas de proveedores que Tokengate puede servir** (`Catalog.supported?/1`) | 181 de 220 proveedores · 6101 ofertas · 2953 modelos. Los 39 no soportados no entran al picker porque no son enrutables |
| D2 | `models.name` (la API pública que mandan los clientes) se **prellena con el id de models.dev** y queda **editable** | `openai/gpt-5-nano`, `glm-5.2`… El operador puede acortarlo; el vínculo con el catálogo se guarda aparte (`models.catalog_model_key`) y no depende del nombre |
| D3 | Los precios del catálogo **prellenan** `model_providers.*_cost_per_million` (fallback de facturación) | Nada se factura distinto por sí solo; el operador ve el precio real y lo corrige si quiere |
| D4 | Se agrega `models.lab_key` → `labs` (FK nullable) y el logo del lab en la tarjeta | Reusa la tabla `labs` que ya existe y ya trae logos |
| D5 | El refresh **no agrega descargas**: reusa los dos payloads que `CatalogRefreshWorker` ya baja | `api.json` ya se baja (worker:75) y `models.json` ya se baja para labs (worker:357) |
| D6 | El id de la oferta = el id que models.dev publica por proveedor, y se usa como `provider_model` sugerido | Hoy ese id **es igual** a la clave canónica (medido: 0 diferencias en 7843 entradas); se mantiene el hint del `/models` en vivo como validación |
| D7 | `model_type` default `llm`; embeddings por lista curada en código | models.json no distingue embedding de chat (ver `catalog.ex:41-46`); solo 4 ids canónicos son embeddings por nombre |

---

## 1. Estado actual (verificado en código)

| Pieza | Estado | Evidencia |
|---|---|---|
| Espejo de proveedores models.dev | ✅ tabla `catalog_providers` + refresh + seed | `20260915234500_models_dev_catalog.exs`, `catalog_provider.ex`, `catalog_refresh_worker.ex` |
| Picker de proveedores (buscador + activar) | ✅ modal con búsqueda en memoria | `providers_live.ex:152` (`load_catalog`), `:231`, `:244`, `:251`, `:647`, render `:841-916` |
| Alta de credencial (API key) | ✅ modal alias + key, en su propia página | `providers_live.ex:397/424`, render `:1088-1118`; `Providers.create_credential/1` en `providers.ex:287` |
| Modelos virtuales | ✅ `models` (nombre virtual, ctx, tipo, precios de mercado display-only) + `model_providers` (credencial + `provider_model` + prioridad + scope) | `model.ex:15-34`, `model_provider.ex:60-109` |
| Alta de modelo | ⚠️ **100% a mano**: nombre, contexto y precios escritos por el operador | `models_live.ex:147` (`new_model`), form `:1502-1587` |
| Asignar proveedor a un modelo | ⚠️ **lista plana de TODAS las credenciales activas**, sin agrupar por proveedor ni crear key en el momento | `models_live.ex:114` (`credentials_for_select`), select `:1644-1652` |
| Sugerencia de `provider_model` | ✅ pide `/models` en vivo al proveedor y ofrece dropdown | `models_live.ex:748` (`fetch_provider_models`), `:782`, render `:1669-1688` |
| Catálogo de laboratorios | ✅ tabla `labs`, derivada de los mismos payloads | `lab_catalog.ex:134` (`derive/3`), worker `:354` (`refresh_labs`) |

**Lo que falta, en una frase:** models.dev ya está integrado a nivel *proveedor* y
*lab*, pero **no a nivel modelo** — y el modal de "Asignar Proveedor" no permite
crear la credencial que el modelo necesita.

---

## 2. Qué publica models.dev (medido hoy con curl)

| Payload | Tamaño | Contenido |
|---|---|---|
| `https://models.dev/api.json` | 4.5 MB | 220 proveedores; cada uno con `models` (map id → metadata **con `cost`**) |
| `https://models.dev/models.json` | 310 KB | 403 modelos **canónicos** (sin `cost`), con descripción, `limit`, `modalities`, `release_date`, `license`, `open_weights` |

Números que importan para el diseño:

- **7843** ofertas proveedor→modelo en total; **6101** bajo proveedores soportados; **2953** ids distintos alcanzables.
- **2035** de esos ids los sirve **un solo** proveedor soportado.
- **3449** ids servidos **no** son canónicos (`@cf/...`, `accounts/fireworks/routers/...`, `glm-5.2`…): el picker **no puede** basarse solo en `/models.json`.
- **129** modelos canónicos **no** los sirve nadie → existen en el catálogo pero no son enrutables.
- **7423 / 7843** ofertas traen `cost` (`input`, `output`, `cache_read`, `cache_write`, a veces `tiers` por tamaño de contexto).

Conclusión: la fuente del picker es **la oferta** (proveedor sirve modelo) y la
metadata rica (descripción, lab, modalidades, fechas) viene del canónico cuando
existe, o del propio registro del proveedor cuando no.

---

## 3. Modelo de datos

Dos tablas espejo nuevas (mismo contrato que `catalog_providers`/`labs`: las
escribe **solo** el refresh, nunca el operador, nunca se borran — `status:
"stale"`).

```
catalog_models                      -- dimensión: el modelo
  key              pk   -- id de models.dev ("openai/gpt-5-nano", "glm-5.2")
  name                  -- "GPT-5 Nano"
  lab_key               -- "openai" (prefijo del id; join a labs)
  description
  canonical     bool    -- true si viene de /models.json
  context_limit, output_limit
  cost_input, cost_output, cost_cache_read, cost_cache_write   -- solo canónicos
  modalities    jsonb   -- %{input: [...], output: [...]}
  features      jsonb   -- reasoning/tool_call/attachment/structured_output/open_weights
  release_date, last_updated, license
  status                -- active | stale
  fingerprint, fetched_at
  timestamps

catalog_model_offers                -- hecho: un proveedor sirve un modelo
  id            pk (uuid)
  provider_key          -- models.dev provider id → providers.key
  model_key             -- FK lógica a catalog_models.key
  provider_model        -- el id que se manda upstream (hoy == model_key)
  cost_input, cost_output, cost_cache_read, cost_cache_write
  tiers         jsonb   -- [{tier: %{type: "context", size: 32000}, cost...}]
  limit_context, limit_output   -- override del proveedor, si lo trae
  status, fingerprint, fetched_at
  índices únicos: (provider_key, model_key)
```

Más una columna en `models`:

- `models.catalog_model_key` (string, nullable) — de qué modelo de models.dev
  salió esta fila. `nil` = custom a mano. Habilita "re-sincronizar metadata" y el
  badge "ya dado de alta" en el picker.
- `models.lab_key` (string, nullable, FK a `labs.key`) — decisión D4.

Volumen: ~2953 filas + ~6101 filas por refresh. Mismo patrón que labs
(`insert_all`/upsert con comparación de `fingerprint`, nada se borra) — el costo
de escritura lo mide el `fingerprint`, no el diff.

---

## 4. Flujos de UI

### A) Nuevo Modelo → pestaña «Desde catálogo» (nuevo)

1. `Nuevo Modelo` (`models_live.ex:1217`) abre un modal con **dos pestañas**:
   `Desde catálogo` (default) y `Personalizado`.
2. En `Desde catálogo`: input de búsqueda con `phx-change` que filtra **en
   memoria** los ~2953 modelos (calcado de `filter_catalog/2`,
   `providers_live.ex:647`: nada de query por tecla). Busca por nombre, id y lab.
3. Cada fila muestra lo que models.dev sabe: logo del lab, nombre, id,
   `ctx`, precio in/out, **"N proveedores"** y badge **"ya existe"** si
   `models.name` ya está dado de alta.
4. Click en la fila → `pick_catalog_model` prellena el formulario existente
   (`name`, `context_window`, `model_type`) + `catalog_model_key`.
   El formulario sigue siendo el de hoy: todo editable, nada bloqueado.
5. Guardar → crea el modelo (`Providers.create_model/1`) y **encadena** el paso B
   con el modelo recién creado y la lista de proveedores **ya filtrada a los que
   sirven ese modelo**.

### B) API key + Proveedor, en el mismo modal (evoluciona `models_live.ex:1625`)

La **API key manda**: el proveedor de una fila es, por definición, el que emitió
la key, así que el modal lo **deriva** de ella en vez de pedirlo como paso
previo (la lista plana de credenciales se conserva, pero ya no se exige elegir
proveedor antes).

1. **Credencial**: select con las credenciales activas (todas, o solo las del
   proveedor que se haya filtrado) + botón **«＋ Nueva API key»** que despliega
   alias + key (los mismos campos de `providers_live.ex:1088`), crea la
   credencial (`Providers.create_credential/1`, `providers.ex:287`) y **la deja
   seleccionada**. Al elegirla queda fijado el proveedor del chip.
2. **Proveedor (derivado / filtro)**: el buscador sigue ahí, pero filtra las API
   keys por proveedor; los proveedores que sirven el modelo siguen listados con
   su precio de lista, y el chip muestra el proveedor que resolvió la key (aunque
   no publique oferta para este modelo: el proveedor lo nombra la credencial).
   "Lo que la key necesite" queda cubierto por lo que ya existe por proveedor:
   `path_overrides` (modal Capacidades), `max_rpm`/`max_concurrent`/timeout a
   nivel proveedor, y `sticky_ttl`/`service_tier` a nivel model_provider.
3. `provider_model` y los costos manuales se **prellenan con la oferta**
   (`Providers.offer_for/2`) del proveedor de la key para ese modelo — solo en
   los campos vacíos — y se mantiene el dropdown del `/models` en vivo (`:748`)
   como validación/override.

### C) Modelo custom a mano (se conserva)

Pestaña `Personalizado` = el formulario actual, sin `catalog_model_key`. Nada se
pierde: es el mismo camino de hoy, solo reubicado en una pestaña.

### D) Modelo ya dado de alta → nueva API key

El botón `Asignar Proveedor` (`models_live.ex:1333`) abre **el mismo modal B**.
La mejora concreta que se pide —"solo mejorar el modal"— es exactamente la de B:
**la key resuelve el proveedor** (no hace falta elegir proveedor primero) y
**crear la key sin salir** a `/catalog/providers`. Para asignar la **segunda**
key de un modelo solo hay que repetir el paso, con el select de credencial
marcando cuáles ya están usadas en ese scope (hoy ya existe la validación:
`Providers.list_available_credentials_for_scope/3`, `providers.ex:638`).

---

## 5. Cambios por archivo

| Archivo | Cambio |
|---|---|
| `priv/repo/migrations/<ts>_catalog_models.exs` **(nuevo)** | `catalog_models`, `catalog_model_offers`, índices, `models.catalog_model_key`, `models.lab_key` |
| `lib/tokengate/providers/catalog_model.ex` **(nuevo)** | Schema espejo + `fingerprint/1` (patrón `catalog_provider.ex`) |
| `lib/tokengate/providers/catalog_model_offer.ex` **(nuevo)** | Idem para las ofertas |
| `lib/tokengate/providers/model_catalog.ex` **(nuevo)** | `derive/2` desde los dos payloads, `search/2`, lista curada de embeddings (D7), `encode_snapshot/1` |
| `lib/tokengate/providers/catalog_refresh_worker.ex` | Paso `refresh_models/2` con los payloads **ya descargados**; upsert por fingerprint; sweep a `stale`; warnings del tipo `models_fetch_failed` (patrón `refresh_labs`, `:354-380`) |
| `lib/tokengate/providers/catalog_seed.ex` | `seed_models_if_empty/0` desde snapshot vendorizado (instancia nueva sin red) |
| `lib/tokengate/providers.ex` | `list_catalog_models/1`, `search_catalog_models/1`, `offers_for_model/1`, `providers_serving/1`, `create_model_from_catalog/1` |
| `lib/tokengate/providers/model.ex` | `catalog_model_key`, `lab_key` (+ cast) |
| `lib/tokengate_web/live/models_live.ex` | Asignaciones del picker, `pick_catalog_model`, `search_catalog_models`, `select_offer_provider`, `new_credential_inline`; modal A con pestañas; modal B proveedor→credencial con "＋ Nueva API key" |
| `priv/models_dev/models_catalog.json` **(nuevo)** | Snapshot vendorizado (el `mix tokengate.labs.snapshot` ya existe como precedente, `lib/mix/tasks/tokengate.labs.snapshot.ex`) |
| `test/tokengate/providers/model_catalog_test.exs` **(nuevo)** | derive/edge cases (id sin lab, oferta sin cost, canónico sin proveedor) |
| `test/tokengate/providers/catalog_refresh_worker_test.exs` | Extender con el espejo de modelos (el test ya existe) |
| `test/tokengate_web/live/models_live_test.exs` | Picker → prefill → crear; proveedor→key inline; "ya existe"; custom intacto |

Router: **sin cambios** (la página sigue en `/catalog/models`, `router.ex:159`).

---

## 6. Fases

| Fase | Alcance | Verificación |
|---|---|---|
| **F1 — espejo** | Migración + schemas + derivación + refresh + seed + snapshot. Sin UI | `mix test test/tokengate/providers/catalog_refresh_worker_test.exs test/tokengate/providers/model_catalog_test.exs` |
| **F2 — picker** | Modal A con pestañas, búsqueda, prefill, `catalog_model_key`, filas con metadata + badge "ya existe" | `mix test test/tokengate_web/live/models_live_test.exs` |
| **F3 — proveedor + key** | Ofertas en el modal B, proveedor primero, "＋ Nueva API key" inline, prefill de costos | idem + test de creación de credencial desde el modal |
| **F4 — pulido** | Logo del lab en la tarjeta, "re-sincronizar del catálogo", marcar modelos con 0 proveedores | `mix precommit` |

Cada fase termina en `mix precommit` (`mix.exs:97`: compile `--warnings-as-errors`,
deps.audit, format, test).

---

## 7. Riesgos y no-objetivos

- **Volumen del refresh**: +9054 filas por corrida. Se mitiga con `insert_all` +
  fingerprint (patrón labs) y sin borrar nunca. El payload ya se descarga hoy.
- **models.dev es comunitario**: un id publicado puede no ser el que acepta el
  upstream. Por eso `provider_model` queda editable y el `/models` en vivo sigue
  como sugerencia; nunca se fija en duro.
- **Nombre público del modelo**: `models.name` es lo que mandan los clientes en
  `model`. D2 lo prellena pero lo deja editable — cambiar el nombre después rompe
  a los clientes que ya lo usan, igual que hoy.
- **2035 ids los sirve un solo proveedor**: si ese proveedor no está soportado,
  el modelo no aparece en el picker. Es correcto (no sería enrutable), pero
  explica por qué el picker muestra 2953 y no 3723.
- **No-objetivos**: no se toca la cadena de facturación (los precios del catálogo
  solo prellenan fallbacks editables), no se toca el routing, no se renombran
  modelos existentes.

---

## 8. Preguntas abiertas (resueltas)

1. **Nombre interno por default** → **id sin el prefijo del lab** (`openai/gpt-5-nano`
   → `gpt-5-nano`), editable. Implementado en `ModelCatalog.short_name/1`.
2. **Costos** → **se prellenan y quedan editables**.
3. **Alcance** → F1+F2+F3 de una.

---

## 9. Lo que cambió respecto al plan (hallazgos al implementar)

### 9.1 `/models.json` no publica precios — el `cost_*` del espejo sale de la mejor oferta

Medido: **0 de los 403 canónicos traen `cost`**. El plan asumía que el precio de
referencia del modelo venía del canónico; no existe. El precio real vive solo en
el registro de cada proveedor, así que el `cost_*` de `catalog_models` es la
**oferta más barata** que sirve el modelo (`cheapest_by_model/1`): una oferta sin
precio nunca le gana a una que sí lo tiene, y entre dos con precio gana el menor
input. Es lo honesto: "este modelo se consigue desde aquí".

### 9.2 El seed y el refresh se separaron

`CatalogSync.sync/0` sembraba los mirrors en cada llamada, y el refresh lo
llamaba para materializar. Con el mirror de modelos eso encadena mal: el seed
insertaba las ~3120 filas del snapshot y el refresh reportaba `models_inserted=0`
(el writer era el seed, no la corrida). Ahora:

- `CatalogSync.sync/0` = **boot**: siembra los tres mirrors y materializa.
- `CatalogSync.materialize/0` = **refresh**: solo materializa, no siembra.

Con eso una corrida real reporta `models_in=3120 offers_in=6100`, y la segunda
corrida reporta ceros (idempotente por fingerprint).

### 9.3 Los ids de models.dev no son ids de DOM válidos

`openai/gpt-5-nano` y `glm-5.2` no son selectores CSS válidos: un `id` con `/` o
`.` rompe cualquier `element/2`. Se renderiza con `dom_key/1` (`/` → `-`,
`.` → `_`), y el valor real viaja en `phx-value-key`.

### 9.4 Un formulario dentro de otro se rompe (y dos bugs de LiveView)

El buscador de proveedores vive **dentro** de `#model-provider-form`. Un `<form>`
anidado lo descarta el parser HTML y parte el form externo en dos: los campos
posteriores quedaban huérfanos y el submit submitía a medias. Los buscadores son
**inputs sueltos** (`phx-change` en el input, no en un form envolvente).

El form de API key es **hermano**, no hijo, del form de `model_provider`. Y el
`catalog_model_key` viaja como `<input type="hidden">`: no lo teclea nadie, pero
tiene que llegar al insert o la fila se guarda como custom.

### 9.5 El `:if` de HEEx no acepta un string como booleano

`@provider_form_provider_key and ...` revienta con `BadBooleanError` (el
`provider_key` es un string, `and` exige booleano estricto). Va como
`!is_nil(@provider_form_provider_key) and ...`.

### 9.6 Detalles de implementación que no eran obvios

- **Snapshot gzipeado**: 2.7 MB de JSON → **295 KB** en gzip, y se lee en
  runtime (no entra al beam).
- **`catalog_model_offers` necesita `primary_key: false` + `add :id, :binary_id`**:
  el default de Ecto es un bigserial entero, que no puede guardar el uuid que el
  schema autogenera.
- **`insert_all` por lotes**: las ~6000 ofertas revientan el techo de 65535
  bind-params de Postgres; van de 500 en 500.
- **`lab_key` es link suave, no FK**: dos labs canónicos (`ai21`,
  `motif-technologies`) no existen en la tabla `labs`, y un lab faltante no puede
  bloquear un modelo real.
- **`lab_key` solo para `lab/model`**: `accounts/fireworks/routers/kimi-latest`
  tiene un path propio cuyo primer segmento es una cuenta, no un lab. Antes
  atribuía la fila a un lab "accounts" que no existe.

### 9.7 Verificación

| Qué | Resultado |
|---|---|
| `mix precommit` | **1488 tests, 0 fallos** |
| Refresh real contra models.dev | `:ok` en ~1.5-2 s, 0 warnings, `models=3120 offers=6100` |
| Segunda corrida | `models_in=0 offers_in=0` (idempotente) |
| Snapshot vendorizado | 3120 modelos / 6100 ofertas, 295 KB gzip |
| `offers` que difieren del snapshot | 0 (mismo derivador en los dos caminos) |

Tests nuevos: `test/tokengate/providers/model_catalog_test.exs` (15) y los
describe `model catalog picker` / `provider then API key` en
`models_live_test.exs` (10), más 5 en `catalog_refresh_worker_test.exs`.

### 9.8 La relación con el proveedor se deriva de la API key

Síntoma: el modal pedía elegir proveedor **antes** de la key, aunque el
proveedor no es una decisión aparte — cada credencial pertenece a un proveedor y
`model_providers` cuelga de la credencial (`credential_id`), no del proveedor.
La key es lo único que el operador necesita elegir.

Ahora `provider_form_changed` (`models_live.ex`) llama a
`apply_credential_provider/2`: resuelve el proveedor de la key elegida
(`credentials_for_select` → `provider`), lo deja fijado en el chip, y aplica
`put_offer_defaults/2` con `Providers.offer_for/2` (el modelo del proveedor y
los costos de lista de esa oferta, **solo en campos vacíos**). El buscador de
proveedores no se va: filtra las keys, y el placeholder del select ya no exige
haber elegido uno.

Dos matices que importan:

- **Sin oferta no hay precio.** Un proveedor que no sirve el modelo (sin fila en
  `catalog_model_offers`) igual resuelve el chip — el nombre sale de la
  credencial, ver `provider_chip_name/3` — pero no rellena nada.
- **Abrir en edición también rellena**: si la fila ya tiene proveedor
  identificado (su credencial lo dice) y el precio manual está vacío, la oferta
  llegó como default del form. Es un valor **visible y editable**, no un write
  silencioso: nada se guarda hasta pulsar Guardar, y si el precio ya existía,
  el del operador gana.

