# TokenGate

Gateway autohospedado para modelos de lenguaje (LLM). Proxy compatible con la API de OpenAI que enruta peticiones a múltiples proveedores con round-robin, fallback, circuit breaker, presupuestos, observabilidad y control de costos multi-dimensión.

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

- **Round-robin** entre proveedores equivalentes
- **Fallback** automático ante errores
- **Circuit breaker** por proveedor — abre tras N fallos, semi-abre para probar recuperación
- **Sticky routing** — sesiones pegadas a un proveedor
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
- **Roles**: `admin` (global) y `user` (por equipo)
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
| `PHX_HOST` | Host público (prod) | `example.com` |
| `TOKENGATE_ADMIN_EMAIL` | Email del admin root | `admin@tokengate.local` |
| `TOKENGATE_ADMIN_PASSWORD` | Password del admin root | `tokengate-admin-secret-1` |
| `WEBHOOK_SECRET` | HMAC secret para webhooks | — |
| `GOOGLE_OAUTH_CLIENT_ID` | Google OAuth client ID | — |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Google OAuth client secret | — |
| `GOOGLE_OAUTH_REDIRECT_URI` | URL de callback | `https://{host}/auth/google/callback` |
| `GOOGLE_OAUTH_ALLOWED_DOMAINS` | Dominios permitidos (comma-separated) | vacío = todos |

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
├── routing/           # Router, round-robin, circuit breaker, priorities
├── limits/            # Budget tracking (BEAM :atomics)
├── budgets/           # Spend queries (Postgres)
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

Diseñado para desplegar vía Coolify con releases de Elixir.

```bash
# Build release
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release

# Run
PHX_SERVER=true _build/prod/rel/tokengate/bin/tokengate start
```

Ver `config/runtime.exs` para configuración de producción.

## Licencia

Privado.
