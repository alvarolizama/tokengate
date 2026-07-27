<div align="center">
  <img src="priv/static/images/logo.svg" alt="TokenGate logo" width="96">
  <h1>TokenGate</h1>
</div>

Gateway autohospedado para modelos de lenguaje (LLM). Proxy compatible con la API de OpenAI que enruta peticiones a múltiples proveedores con selección por prioridad y sticky routing, fallback, circuit breaker, presupuestos, observabilidad y control de costos multi-dimensión.

## Stack

- **Elixir + Phoenix LiveView** (v1.8) — UI en tiempo real, sin SPA
- **PostgreSQL** — persistencia (vía Ecto)
- **Oban** — jobs asíncronos (logs, webhooks OTLP)
- **BEAM** — estado efímero (`:atomics`, `:gen_statem`, ETS)
- **Tailwind CSS v4** — estilos
- **Req** — cliente HTTP para upstreams y OAuth
- **bcrypt_elixir** — hashing de credenciales

## Features

### Proxy API

- Endpoint `POST /v1/chat/completions` compatible con OpenAI
- Endpoint `GET /v1/models` para listar modelos disponibles
- Autenticación vía bearer API key
- Streaming de respuestas

### Enrutamiento inteligente

- **Selección por prioridad** — el primer proveedor disponible (prioridad ASC) gana
- **Sticky routing** — la misma API key se pega al mismo proveedor (preserva prompt caches)
- **Fallback** automático ante errores (hasta 3 intentos, excluyendo credenciales fallidas)
- **Circuit breaker** por credencial — abre tras N fallos, semi-abre para probar recuperación
- **Reglas de reroute** — por longitud de contexto o presencia de imágenes
- **Prioridades** — orden de preferencia configurable por modelo

### Control de costos (4 dimensiones)

Cada request se registra con 4 métricas de costo:

| Dimensión | Campo | Qué mide |
|-----------|-------|----------|
| **Costo de mercado** | `estimated_cost_usd` | Lo que costaría a precio público del modelo |
| **Costo del proveedor** | `cost_usd` | Lo que el proveedor cobra (pricing row) |
| **Costo real pagado** | `provider_cost_usd` | Lo que realmente pagaste (preferencia al costo reportado por el proveedor) |
| **Ahorro** | `savings_usd` | `estimado - real` — cuánto ahorras vs precio de mercado |

Soporta proveedores `pay_per_token` (pago por token) e `included` (suscripción/RPM-limited).

### Gestión multi-tenant

- **Equipos** → **Miembros** → **API keys**
- **Roles**: `admin` (global) y `manager`/`user` (por equipo)
- **Alias de modelos** — mapea `gpt-4` → proveedor+modelo real, con grants por equipo y por miembro
- **Presupuestos y límites** por equipo y por miembro:
  - Gasto diario y mensual (USD)
  - Concurrencia máxima
  - RPM (requests por minuto)
  - Bloqueo automático al superar límites
  - Overrides individuales (`extra_daily_budget_usd`, etc.)

### Autenticación

- **Password** — email + password con Bcrypt
- **Google OAuth** — botón "Entrar con Google" en el login
  - Usuarios existentes pueden vincular su cuenta de Google
  - Auto-registro opcional por dominio allowlist
  - Suspended users no pueden entrar
- **Session-based** — cookies firmadas, no JWT
- **Root admin** — creado via env vars en seeds, no puede ser suspendido

### Dashboard de estadísticas

Dashboard principal (`/dashboard`) con KPIs y gráficas por periodo (Hoy, 7d, 30d, 90d):

- **Costo por hora/día** — barras por bucket con tooltips
- **Requests por hora/día** — volumen de tráfico
- **Ahorro por hora/día** — ahorro vs precio de mercado
- **Top modelos por costo real** — barras horizontales (top 5)
- **Desglose** por modelo, API key y equipo
- Actualización en tiempo real vía PubSub (con debounce para no ahogar Postgres)

Sección `/dashboard/stats` con 3 vistas:

- **Resumen** (`/dashboard/stats`) — KPIs globales + Top 5 modelos/equipos/miembros
- **Por modelo** (`/dashboard/stats/models`) — tabla de todos los modelos con drill-down:
  - Costo de mercado vs real vs ahorro
  - Desglose por proveedor (performance y costo)
  - Equipos y miembros que usan el modelo
- **Por equipo** (`/dashboard/stats/teams`) — tabla de todos los equipos con drill-down:
  - Vista global del equipo (KPIs)
  - Modelos usados por el equipo
  - Miembros del equipo con sus consumos
- **Periodos**: 7d, 30d, 90d
- **CSV export** — descarga cualquier tabla visible como CSV
- **Scoping por rol**: admin ve todo, manager ve sus equipos, user ve solo lo suyo

### Observabilidad

- **Logs de petición** asíncronos (Oban) — latencia, tokens, costo, status, agente
- **Webhooks OTLP** compatibles con OpenRouter
- **Audit log** — cambios administrativos
- **LiveDashboard** en dev

### Control de acceso

| Ruta | Admin | Manager | User |
|------|-------|---------|------|
| Dashboard, Stats, Logs | ✅ | ✅ (sus equipos) | ✅ (suyo) |
| Equipos y miembros | ✅ | ✅ (sus equipos) | ❌ |
| Modelos, Proveedores | ✅ | ❌ | ❌ |
| Usuarios, API Keys | ✅ | ❌ | ❌ |

El sidebar solo muestra links de configuración a admins.

## Inicio rápido

### Prerequisitos

- Elixir 1.15+
- PostgreSQL 14+
- Node.js 20+ (para assets)

### Instalación

```bash
# Clonar
git clone <repo-url> tokengate
cd tokengate

# Instalar dependencias, crear DB, migrar y sembrar
mix setup

# Arrancar servidor
mix phx.server
```

El server arranca en `http://localhost:4000`.

### Credenciales por defecto (seed)

| Campo    | Valor                      |
|----------|----------------------------|
| Email    | `admin@tokengate.local`    |
| Password | `tokengate-admin-secret-1` |

Override con env vars: `TOKENGATE_ADMIN_EMAIL`, `TOKENGATE_ADMIN_PASSWORD`.

## Configuración

### Variables de entorno

| Variable | Descripción | Default |
|----------|-------------|---------|
| `DATABASE_URL` | URL de conexión Postgres (prod) | — |
| `SECRET_KEY_BASE` | Clave de firma (prod) | — |
| `PORT` | Puerto del servidor | `4000` |
| `PHX_HOST` | Host público (prod, sin scheme ni puerto) | requerida en prod |
| `PHX_SCHEME` | Scheme para URLs generadas (`http`/`https`) | `https` |
| `PHX_PORT` | Puerto para URLs generadas | `443` |
| `TOKENGATE_ADMIN_EMAIL` | Email del admin root | `admin@tokengate.local` |
| `TOKENGATE_ADMIN_PASSWORD` | Password del admin root | `tokengate-admin-secret-1` |
| `WEBHOOK_SECRET` | HMAC secret para webhooks | — |
| `GOOGLE_OAUTH_CLIENT_ID` | Google OAuth client ID | — |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Google OAuth client secret | — |
| `GOOGLE_OAUTH_REDIRECT_URI` | URL de callback | `{scheme}://{host}/auth/google/callback` |
| `GOOGLE_OAUTH_ALLOWED_DOMAINS` | Dominios permitidos (comma-separated) | vacío = sin auto-registro (fail-closed) |
| `SKIP_MIGRATIONS` | `1` = el entrypoint Docker no migra/seedea | — |

### Google OAuth (opcional)

1. Crea un proyecto en [Google Cloud Console](https://console.cloud.google.com/)
2. Habilita Google+ API y crea credenciales OAuth 2.0
3. Configura la URI de redirección: `http://localhost:4000/auth/google/callback` (dev) o `https://{host}/auth/google/callback` (prod)
4. Setea las env vars:

```bash
GOOGLE_OAUTH_CLIENT_ID=tu-client-id.apps.googleusercontent.com
GOOGLE_OAUTH_CLIENT_SECRET=tu-client-secret
GOOGLE_OAUTH_ALLOWED_DOMAINS=tu-empresa.com,otro-dominio.com
```

Sin estas vars, el botón "Entrar con Google" no aparece funcional.

## Uso del proxy

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer tg-xxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Hola"}]
  }'
```

El alias `gpt-4` se resuelve al proveedor y modelo configurado en el dashboard.

### Headers opcionales

| Header | Descripción |
|--------|-------------|
| `X-Agent-Type` | Tipo de agente (`claude-code`, `cursor`, etc.) |
| `X-Title` | Título del agente |
| `HTTP-Referer` | Referer |

## Estructura del proyecto

```
lib/tokengate/
├── accounts/          # Users, teams, members, API keys
├── providers/         # Providers, credentials, aliases, pricing
├── routing/           # Router, prioridad + sticky, circuit breaker, reglas
├── limits/            # Rate limits: RPM + concurrencia (ETS)
├── budgets/           # Presupuestos diario/mensual (ETS + sync a Postgres)
├── logs/              # Request logs (async via Oban)
├── metrics/           # Rollup queries (dashboard stats)
├── observability/     # OTLP webhooks, destinations
├── proxy/             # Cost calculator, OpenAI adapter, usage normalizer
└── auditing/          # Audit log

lib/tokengate_web/
├── controllers/       # Page, Session, Proxy, OAuth, StatsExport
├── oauth/             # Google OAuth helper module
├── live/              # Dashboard, Stats, Teams, Users, Keys, Logs, Models, Providers
├── plugs/             # ApiAuth, DashboardAuth
└── components/        # Layouts, core components
```

## Flujo de trabajo

### Setup inicial (admin)

1. **Login** con credenciales de seed
2. **Proveedores** → crear proveedor (OpenAI, Anthropic, etc.) + credenciales (API keys)
3. **Modelos** → crear alias de modelo (ej: `gpt-4o`) + asignar proveedor con pricing
4. **Equipos** → crear equipo con presupuestos y límites
5. **Equipos → Miembros** → agregar miembros por email, generar API keys
6. **Equipos → Aliases** → grant de modelos al equipo
7. Compartir API keys con los miembros

### Uso diario

- **Dashboard** — ver consumo en tiempo real, KPIs, breakdowns
- **Estadísticas** — análisis histórico con drill-down por modelo/equipo, exportar CSV
- **Logs** — inspeccionar requests individuales
- **Usuarios** — crear/editar/suspender usuarios, resetear passwords

## Comandos útiles

```bash
mix setup              # deps + DB + assets
mix phx.server         # servidor dev
mix test               # tests (crea DB de test automáticamente)
mix precommit          # compile + warnings + format + test
mix ecto.reset        # drop + create + migrate + seed
mix ecto.migrate       # migrar
```

## Deploy

Diseñado para desplegar vía **Coolify** con el `Dockerfile` multi-stage del repo
(builder `hexpm/elixir` → runtime `debian:bookworm-slim`, non-root).

### Docker

```bash
# Build
docker build -t tokengate .

# Run (el entrypoint crea la DB si falta, migra y seedea el admin)
docker run -p 4000:4000 \
  -e DATABASE_URL=ecto://postgres:postgres@host.docker.internal/tokengate \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -e WEBHOOK_SECRET=$(openssl rand -hex 32) \
  -e PHX_HOST=tokengate.example.com \
  tokengate
```

El entrypoint (`docker/entrypoint.sh`) corre `Tokengate.Release.setup/0`
(create DB → migrate → seed admin, idempotente) antes de arrancar. Una
migración fallida aborta el boot y Coolify hace rollback. `SKIP_MIGRATIONS=1`
lo salta (contenedores one-off).

### Coolify

- **Build pack**: Dockerfile (raíz del repo)
- **Start command**: la provee el entrypoint — no hace falta pre-deploy hook
- **Env vars** (runtime): `DATABASE_URL`, `SECRET_KEY_BASE`, `WEBHOOK_SECRET`,
  `PHX_HOST`, y opcionales `PHX_SCHEME`, `PHX_PORT`, `GOOGLE_OAUTH_*`,
  `TOKENGATE_ADMIN_EMAIL`, `TOKENGATE_ADMIN_PASSWORD`

### HTTP plano (VPN / sin TLS)

`force_ssl` es compile-time en Phoenix, así que desactivarlo requiere
**rebuild** con el build arg:

```bash
docker build --build-arg DISABLE_FORCE_SSL=1 -t tokengate:http .
```

y en runtime `PHX_SCHEME=http` (para que las URLs generadas usen http).

### Release manual (sin Docker)

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release

# setup (create DB → migrate → seed admin) o solo migrate:
_build/prod/rel/tokengate/bin/setup
_build/prod/rel/tokengate/bin/migrate

# arrancar
_build/prod/rel/tokengate/bin/server
```

Ver `config/runtime.exs` para la configuración de producción.

## Licencia

[MIT](LICENSE).
