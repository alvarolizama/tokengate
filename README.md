<div align="center">
  <img src="priv/static/images/logo.svg" alt="TokenGate logo" width="96">
  <h1>TokenGate</h1>
  <p>Gateway autohospedado para LLMs. Proxy compatible con OpenAI que enruta a múltiples proveedores con prioridad, sticky routing, circuit breaker, presupuestos y observabilidad en tiempo real.</p>
</div>

## Stack

- **Elixir + Phoenix LiveView v1.8** — UI en tiempo real, sin SPA
- **PostgreSQL** — persistencia (Ecto)
- **Oban** — jobs asíncronos (logs, webhooks OTLP, sync de budgets)
- **BEAM** — estado efímero (`:gen_statem`, ETS)
- **Tailwind CSS v4** — estilos

## Features

### Proxy API

- `POST /v1/chat/completions` y `GET /v1/models` compatibles con OpenAI
- Autenticación vía bearer API key
- Streaming de respuestas (SSE)
- Headers opcionales: `X-Agent-Type`, `X-Title`, `HTTP-Referer`

### Enrutamiento

- **Prioridad + sticky routing** — la misma API key se pega al mismo proveedor (preserva prompt caches) con TTL de 15 min
- **Circuit breaker** por credencial (`:gen_statem`) — abre tras 15 fallos (configurable), cooldown 30s (20s si fue rate limit)
- **Fallback** automático ante errores 5xx/timeout/429
- **Fallback por saturación** — si la credencial está en su límite de concurrencia o RPM, se rebota a la siguiente en la cola de prioridad sin error al cliente
- **Errores de auth** (401/402/403) — desactivan la credencial permanentemente (status → `error`) y hacen fallback

### Errores al cliente

| HTTP | Code | Cuándo |
|------|------|--------|
| 400 | `invalid_request` | Payload malformado |
| 402 | `budget_exceeded` | Gasto mensual del usuario supera su budget |
| 404 | `model_not_found` | Modelo no existe o sin acceso |
| 429 | `rate_limited` / `concurrency_exceeded` | Límites del usuario excedidos |
| 429 | `provider_rate_limited` / `provider_concurrency_exceeded` | Límites de la credencial excedidos |
| 4xx | `upstream_client_error` | El proveedor rechazó el payload — se pasa directo |
| 502 | `upstream_error` | El proveedor falló tras agotar fallback |
| 503 | `no_providers` / `no_available_provider` / `all_providers_down` | Sin candidatos disponibles |
| 500 | `internal_error` | Error no clasificado |

### Control de costos

Cada request registra el **costo reportado por el proveedor** (`provider_cost_usd`). Se confía en lo que el upstream reporta en su respuesta. Soporta `billing_mode` `pay_per_token` (costo por uso) e `included` (suscripción — costo $0).

### Credential Pinning (Exclusive Scope)

Un credential puede ser **global**, **exclusivo para miembro** o **exclusivo para equipo**. Los exclusivos tienen prioridad máxima (priority -1); si fallan, el routing cae al pool global. Constraint de exclusividad en DB. Se configura en **Dashboard > Models** y se ve por miembro en **Teams > Members**.

### Multi-tenant

- **Equipos → Miembros → API keys** con roles `admin` y `user`
- **Servicios** — API keys sin usuario asociado, con límites directos (budget, concurrencia, RPM)
- **Alias de modelos** — mapea `gpt-4` → proveedor+modelo real, con grants por equipo, miembro y servicio
- **Budget mensual por usuario** — el equipo define tope por persona; miembros pueden tener extra budget/concurrencia/RPM (efectivo = team default + extra)
- **Bloqueo automático** al superar límites (402/429 sin tocar al proveedor)

### Dashboard

- **KPIs** — requests, costo, tokens in/out, TPS (períodos: Hoy, 7d, 30d, 90d)
- **Gráficas horarias** — costo, requests, tokens (stacked), TPS
- **Desglose** por modelo, API key y equipo
- **Top 5** equipos y miembros por consumo
- **Logs en vivo** — requests en vuelo, filtros por modelo/equipo/proveedor/estado

### Estadísticas (`/dashboard/stats`)

- Vistas: Resumen, Modelos, Equipos, Servicios, drill-down por miembro
- Rankings de proveedores, modelos, usuarios
- **Export CSV** (`/dashboard/stats/export`)
- **Scoping** — admin ve todo, usuarios ven solo su consumo

### Créditos, Alertas y Settings

- **Créditos** — consumo vs budget mensual por miembro
- **Alertas** — credenciales en `error`, breakers abiertos, miembros sin API key
- **Settings** (zona de peligro) — truncar `request_logs`, reiniciar sticky sessions, reiniciar extras de miembros

### Autenticación

- Password (Bcrypt) + Google OAuth opcional (con allowlist de dominios)
- Impersonación de usuarios (admin) con banner persistente y audit log

### Parámetros configurables

**1. Global (env vars):**

| Variable | Descripción | Default |
|----------|-------------|---------|
| `CIRCUIT_BREAKER_THRESHOLD` | Fallos para abrir el breaker | `15` |
| `CIRCUIT_BREAKER_COOLDOWN_MS` | Cooldown normal (ms) | `30000` |
| `CIRCUIT_BREAKER_RATE_LIMIT_COOLDOWN_MS` | Cooldown si fue 429/529 (ms) | `20000` |
| `FIRST_TOKEN_TIMEOUT_MS` | Timeout al primer token antes de fallback (ms) | `15000` |

**2. Por credencial de proveedor:** `max_rpm`, `max_concurrent`, `receive_timeout_ms`

**3. Por equipo/miembro/servicio:** `monthly_budget_per_user_usd`, `default_concurrency_limit`, `default_rpm_limit` (equipo); `extra_monthly_budget_usd`, `extra_concurrency`, `extra_rpm` (miembro); `monthly_budget_usd`, `concurrency_limit`, `rpm_limit` (servicio).

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
  -H "Authorization: Bearer ***" \
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
| `PHX_PORT` / `PHX_SCHEME` | Puerto / scheme (prod) | — |
| `POOL_SIZE` | Pool de conexiones DB | — |
| `ECTO_SSL` / `ECTO_SSL_VERIFY` | SSL a Postgres | `true` |
| `TOKENGATE_ADMIN_EMAIL` | Email del admin root | `admin@tokengate.local` |
| `TOKENGATE_ADMIN_PASSWORD` | Password del admin root | `tokengate-admin-secret-1` |
| `WEBHOOK_SECRET` | HMAC secret para webhooks | — |
| `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | Google OAuth (opcional) | — |
| `GOOGLE_OAUTH_ALLOWED_DOMAINS` | Dominios allowlist (comma-separated) | vacío |
| `MAILGUN_API_KEY` / `MAILGUN_DOMAIN` | Envío de correos | — |
| `SESSION_SIGNING_SALT` / `SESSION_ENCRYPTION_SALT` / `SESSION_MAX_AGE_SECONDS` | Cookies de sesión | — |

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
