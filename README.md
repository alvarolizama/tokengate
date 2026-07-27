# TokenGate

Gateway autohospedado para modelos de lenguaje (LLM). Proxy compatible con la API de OpenAI que enruta peticiones a múltiples proveedores con round-robin, fallback, circuit breaker, presupuestos y observabilidad.

## Stack

- **Elixir + Phoenix LiveView** (v1.8) — UI en tiempo real, sin SPA
- **PostgreSQL** — persistencia (vía Ecto)
- **Oban** — jobs asíncronos (logs, webhooks OTLP)
- **BEAM** — estado efímero (`:atomics`, `:gen_statem`, ETS)
- **Tailwind CSS v4** — estilos
- **Req** — cliente HTTP para upstreams
- **bcrypt_elixir** — hashing de credenciales

## Features

### Proxy API
- Endpoint `POST /v1/chat/completions` compatible con OpenAI
- Endpoint `GET /v1/models` para listar modelos disponibles
- Autenticación vía bearer API key
- Streaming de respuestas

### Enrutamiento
- **Round-robin** entre proveedores equivalentes
- **Fallback** automático ante errores
- **Circuit breaker** por proveedor (abre tras N fallos, semi-abre para probar recuperación)
- **Sticky routing** — sesiones pegadas a un proveedor
- **Prioridades** — orden de preferencia configurable

### Gestión multi-tenant
- **Organizaciones** → **Equipos** → **Miembros**
- **API keys** por equipo con scopes y límites
- **Roles**: `admin` (global) y `user` (por equipo)
- **Alias de modelos** — mapea `gpt-4` → proveedor+modelo real, con overrides por equipo y por miembro

### Presupuestos y límites
- Límites de gasto por API key y por equipo
- Tracking de consumo en tiempo real (BEAM `:atomics`)
- Bloqueo automático al superar el límite

### Observabilidad
- **Logs de petición** asíncronos (Oban) — latencia, tokens, costo, status
- **Webhooks OTLP** compatibles con OpenRouter
- **Audit log** — cambios administrativos
- **LiveDashboard** en dev

### Dashboard (LiveView)
- Panel de control con sidebar
- Gestión de proveedores, credenciales y suscripciones
- CRUD de equipos, miembros y API keys
- Configuración de alias de modelos y reglas de enrutamiento
- Visor de logs y pricing de modelos

## Inicio rápido

```bash
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

## Uso del proxy

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer tg-<tu-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Hola"}]
  }'
```

El alias `gpt-4` se resuelve al proveedor y modelo configurado en el dashboard.

## Estructura del proyecto

```
lib/tokengate/
├── accounts/          # Users, orgs, teams, members, API keys
├── providers/         # Providers, credentials, aliases, routing rules, pricing
├── routing/           # Router, round-robin, circuit breaker, priorities
├── limits/            # Budget tracking (BEAM :atomics)
├── logs/              # Request logs (async via Oban)
├── observability/     # OTLP webhooks, destinations
└── auditing/          # Audit log

lib/tokengate_web/
├── controllers/       # Page, Session, Proxy
├── live/              # Dashboard, Teams, Keys, Logs, Providers, etc.
├── plugs/             # ApiAuth, DashboardAuth
└── components/        # Layouts, core components
```

## Comandos útiles

```bash
mix setup              # deps + DB + assets
mix phx.server         # servidor dev
mix test               # tests (crea DB de test automáticamente)
mix precommit          # compile + warnings + format + test
mix ecto.reset        # drop + create + migrate + seed
```

## Deploy

Diseñado para desplegar vía Coolify con releases de Elixir. Ver `config/runtime.exs` para configuración de producción.

## Licencia

Privado.
