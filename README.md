<div align="center">
  <img src="priv/static/images/logo.svg" alt="TokenGate logo" width="96">
  <h1>TokenGate</h1>
  <p>Gateway autohospedado para LLMs. Proxy compatible con OpenAI que enruta a múltiples proveedores con prioridad, sticky routing, circuit breaker, presupuestos y observabilidad en tiempo real.</p>
</div>

<table>
  <tr>
    <td><img src="docs/screenshots/dashboard.png" alt="Dashboard"></td>
    <td><img src="docs/screenshots/logs.png" alt="Logs en vivo"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/stats.png" alt="Estadísticas"></td>
    <td><img src="docs/screenshots/providers.png" alt="Proveedores"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/models.png" alt="Modelos"></td>
    <td><img src="docs/screenshots/teams.png" alt="Equipos"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/credits.png" alt="Créditos"></td>
    <td><img src="docs/screenshots/alerts.png" alt="Alertas"></td>
  </tr>
</table>

## Stack

- **Elixir + Phoenix LiveView v1.8** — UI en tiempo real, sin SPA
- **PostgreSQL** — persistencia (Ecto)
- **Oban** — jobs asíncronos (logs, webhooks OTLP)
- **BEAM** — estado efímero (`:atomics`, `:gen_statem`, ETS)
- **Tailwind CSS v4** + DaisyUI — estilos

## Features

### Proxy API

- `POST /v1/chat/completions` y `GET /v1/models` compatibles con OpenAI
- Autenticación vía bearer API key
- Streaming de respuestas

### Enrutamiento

- **Prioridad + sticky routing** — la misma API key se pega al mismo proveedor (preserva prompt caches) con TTL de 60 min
- **Circuit breaker** por credencial — abre tras 15 fallos consecutivos (configurable), semi-abre en 30s (20s si fue rate limit)
- **Fallback** automático ante errores (hasta 3 intentos)
- **Reglas de reroute** por longitud de contexto o presencia de imágenes

### Manejo de errores

TokenGate clasifica cada error del proveedor y decide si reintentar, desactivar la credencial o pasar el error al cliente.

**Clasificación de errores del proveedor:**

| HTTP del proveedor | Razón | ¿Cuenta para breaker? | ¿Fallback? | ¿Desactiva credencial? |
|----|----|----|----|----|
| 401 / 402 / 403 | `auth_error` | ❌ | ✅ | ✅ Sí (status → `error`) |
| 429 / 529 | `rate_limited` | ✅ (cooldown 20s) | ✅ | ❌ |
| 5xx | `server_error` | ✅ (cooldown 30s) | ✅ | ❌ |
| Timeout | `timeout` | ✅ (cooldown 30s) | ✅ | ❌ |
| Otros 4xx | `client_error` | ❌ | ❌ Pasa directo | ❌ |

**Estados de credencial del proveedor:**

| Estado | Significado | ¿Rutiable? |
|--------|-------------|------------|
| `active` | Funcionando | ✅ |
| `disabled` | Desactivada manualmente por admin | ❌ |
| `error` | Auto-desactivada tras 401/402/403 del proveedor | ❌ (requiere reactivación manual) |

**Errores que se le entregan al cliente:**

| HTTP | Code | Cuándo |
|------|------|-------|
| 400 | `invalid_request` | Payload malformado |
| 402 | `budget_exceeded` | El gasto mensual del usuario supera su budget |
| 404 | `model_not_found` | Modelo no existe o sin acceso |
| 429 | `rate_limited` | RPM del usuario excedido |
| 429 | `concurrency_exceeded` | Concurrencia del usuario excedida |
| 429 | `provider_rate_limited` | RPM de la credencial del proveedor excedido |
| 429 | `provider_concurrency_exceeded` | Concurrencia del proveedor excedida |
| 4xx | `upstream_client_error` | El proveedor rechazó el payload (4xx) — se pasa directo |
| 502 | `upstream_error` | El proveedor falló (5xx, timeout) tras agotar fallback |
| 503 | `no_providers` | Modelo sin providers configurados |
| 503 | `no_available_provider` | Todos los providers filtrados o breakers abiertos |
| 503 | `all_providers_down` | Todos los providers fallaron en fallback |
| 500 | `internal_error` | Error no clasificado |

### Control de costos

Cada request registra 4 dimensiones: **costo de mercado** (estimado), **costo del proveedor** (pricing row), **costo real pagado** (lo que pagaste de verdad) y **ahorro** vs precio de mercado. Soporta proveedores `pay_per_token` e `included` (suscripción).

### Multi-tenant

- **Equipos → Miembros → API keys** con roles `admin`, `manager`, `user`
- **Alias de modelos** — mapea `gpt-4` → proveedor+modelo real, con grants por equipo y miembro
- **Budget mensual por usuario** — cada equipo define un tope mensual por persona; los miembros pueden tener extra budget
- **Límites por usuario** — concurrencia y RPM configurables por equipo + extra por miembro
- **Bloqueo automático** al superar límites (402 sin tocar al proveedor)
- **Acceso a modelos extra** — un miembro puede tener grants a modelos fuera de su equipo (solo acceso, sin budget separado)

### Dashboard

- **KPIs en tiempo real** — requests, costo real, ahorro, tokens, TPS
- **Gráficas** de costo, requests y ahorro por hora/día
- **Desglose** por modelo, API key y equipo
- **Estadísticas** con drill-down por modelo y equipo, ranking de proveedores (tiers S/A/B/C/D), patrones de uso, export CSV
- **Logs en vivo** con requests en vuelo, filtros y columnas agrupadas (Identidad, Request, Rendimiento, Costos)
- **Créditos** con barras de progreso y estado por miembro
- **Alertas** — credenciales en error, breakers abiertos, miembros sin crédito

### Autenticación

- Password (Bcrypt) + Google OAuth opcional
- Impersonación de usuarios (admin) con banner persistente y audit log

### Control de acceso

| Ruta | Admin | Manager | User |
|------|-------|---------|------|
| Dashboard, Stats, Logs | ✅ | ✅ (sus equipos) | ✅ (suyo) |
| Equipos y miembros | ✅ | ✅ (sus equipos) | ❌ |
| Proveedores, Modelos | ✅ | ❌ | ❌ |
| Usuarios, API Keys | ✅ | ❌ | ❌ |
| Créditos, Alertas | ✅ | ❌ | ❌ |

### Parámetros configurables

TokenGate tiene 3 niveles de configuración:

**1. Global (env vars)** — aplica a toda la instancia, se setea antes de arrancar:

| Variable | Descripción | Default |
|----------|-------------|---------|
| `CIRCUIT_BREAKER_THRESHOLD` | Fallos consecutivos para abrir el breaker | `15` |
| `CIRCUIT_BREAKER_COOLDOWN_MS` | Tiempo en `open` antes de semi-abrir (ms) | `30000` |
| `CIRCUIT_BREAKER_RATE_LIMIT_COOLDOWN_MS` | Cooldown corto si el fallo fue 429/529 (ms) | `20000` |
| `FIRST_TOKEN_TIMEOUT_MS` | Timeout al primer token del proveedor antes de fallback (ms) | `15000` |

**2. Por credencial del proveedor** (Dashboard > Providers) — límites que protegen al proveedor:

| Campo | Descripción |
|-------|-------------|
| `max_rpm` | RPM máximo que se le manda a esta credencial |
| `max_concurrent` | Requests simultáneos máximos a esta credencial |
| `receive_timeout_ms` | Timeout de respuesta del proveedor (default 180s) |

**3. Por equipo y miembro** (Dashboard > Teams + Team Members) — límites que protegen al usuario:

| Campo | Nivel | Descripción |
|-------|-------|-------------|
| `monthly_budget_per_user_usd` | Equipo | Tope mensual por persona |
| `default_concurrency_limit` | Equipo | Concurrencia por usuario (default 5) |
| `default_rpm_limit` | Equipo | RPM por usuario (default 60) |
| `extra_monthly_budget_usd` | Miembro | Extra budget mensual que se suma al del equipo |
| `extra_concurrency` | Miembro | Extra concurrencia que se suma al del equipo |
| `extra_rpm` | Miembro | Extra RPM que se suma al del equipo |

El límite efectivo del usuario siempre es `team default + member extra`.

## Inicio rápido

```bash
git clone <repo-url> tokengate && cd tokengate
mix setup    # deps + DB + assets
mix phx.server
```

El server arranca en `http://localhost:4000`.

**Credenciales de seed:** `admin@tokengate.local` / `tokengate-admin-secret-1`
(override con `TOKENGATE_ADMIN_EMAIL` y `TOKENGATE_ADMIN_PASSWORD`)

## Uso del proxy

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer tg-..." \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4", "messages": [{"role": "user", "content": "Hola"}]}'
```

Headers opcionales: `X-Agent-Type`, `X-Title`, `HTTP-Referer`

## Configuración

| Variable | Descripción | Default |
|----------|-------------|---------|
| `DATABASE_URL` | URL de conexión Postgres (prod) | — |
| `SECRET_KEY_BASE` | Clave de firma (prod) | — |
| `PHX_HOST` | Host público (prod) | requerida en prod |
| `TOKENGATE_ADMIN_EMAIL` | Email del admin root | `admin@tokengate.local` |
| `TOKENGATE_ADMIN_PASSWORD` | Password del admin root | `tokengate-admin-secret-1` |
| `WEBHOOK_SECRET` | HMAC secret para webhooks | — |
| `GOOGLE_OAUTH_CLIENT_ID` | Google OAuth (opcional) | — |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Google OAuth (opcional) | — |
| `GOOGLE_OAUTH_ALLOWED_DOMAINS` | Dominios allowlist (comma-separated) | vacío |
| `SKIP_MIGRATIONS` | `1` = no migrar en boot | — |
| `ECTO_SSL` | `false` = desactivar SSL a Postgres (local dev) | `true` (SSL on por default) |

> Los parámetros de circuit breaker y timeout de streaming también son env vars — ver [Parámetros configurables](#parámetros-configurables).

## Deploy

Diseñado para **Coolify** con el `Dockerfile` multi-stage del repo. El entrypoint crea la DB, migra y seedea el admin automáticamente.

```bash
docker build -t tokengate .
docker run -p 4000:4000 \
  -e DATABASE_URL=ecto://postgres:postgres@host/tokengate \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -e WEBHOOK_SECRET=$(openssl rand -hex 32) \
  -e PHX_HOST=tokengate.example.com \
  tokengate
```

Para HTTP plano (VPN/sin TLS): `docker build --build-arg DISABLE_FORCE_SSL=1` y `PHX_SCHEME=http` en runtime.

## Comandos útiles

```bash
mix setup          # deps + DB + assets
mix phx.server     # servidor dev
mix test           # tests
mix precommit      # compile + warnings + format + test
mix ecto.reset     # drop + create + migrate + seed
```

## Licencia

[MIT](LICENSE).
