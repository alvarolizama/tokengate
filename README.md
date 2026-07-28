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

- **Prioridad + sticky routing** — la misma API key se pega al mismo proveedor (preserva prompt caches)
- **Circuit breaker** por credencial — abre tras 15 fallos consecutivos, semi-abre en 30s (20s si fue rate limit)
- **Sticky routing** con TTL de 60 min — preserva prompt caches del proveedor por más tiempo
- **Fallback** automático ante errores (hasta 3 intentos)
- **Reglas de reroute** por longitud de contexto o presencia de imágenes

### Control de costos (4 dimensiones)

Cada request registra: **costo de mercado** (estimado), **costo del proveedor** (pricing row), **costo real pagado** (lo que pagaste de verdad) y **ahorro** vs precio de mercado. Soporta proveedores `pay_per_token` e `included` (suscripción).

### Multi-tenant

- **Equipos → Miembros → API keys** con roles `admin`, `manager`, `user`
- **Alias de modelos** — mapea `gpt-4` → proveedor+modelo real, con grants por equipo y miembro
- **Presupuestos** por equipo y miembro: diario/mensual (USD), concurrencia, RPM
- **Bloqueo automático** al superar límites (402 sin tocar al proveedor)
- **Tope presupuestario por equipo** — límite compartido que aplica a todo el equipo

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
