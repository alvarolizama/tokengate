<div align="center">

<img src="docs/headers/tokengate-logo.png" width="96" height="96" alt="TokenGate" />

# TokenGate

**Self-hosted, OpenAI-compatible LLM API gateway built with Elixir, Phoenix LiveView, and PostgreSQL.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-9FE88D.svg)](./mix.exs)
[![Elixir](https://img.shields.io/badge/Elixir-1.15+-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8_LiveView-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-partitioned-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)

</div>

TokenGate sits between your apps or agents and your model providers. Clients keep using standard OpenAI SDKs (`base_url` + `api_key`), while TokenGate handles routing, credential pools, budgets, caching, smart model selection, and telemetry from one admin console.

UI ships in **English** and **Spanish** (`users.locale`, English by default).

## Proxy API (`/v1`)

| Route | Purpose |
|---|---|
| `GET /v1/models` | Models reachable by the presented key (plus `"router"` when enabled) |
| `POST /v1/chat/completions` | Chat completions (streaming SSE and non-streaming) and `"model": "router"` |
| `POST /v1/embeddings` | Non-streaming embeddings |
| `POST /v1/audio/transcriptions` | Multipart speech-to-text passthrough |
| `POST /v1/audio/speech` | Text-to-speech audio passthrough |
| `POST /v1/images/generations` | Image generation passthrough |
| `POST /v1/decisions` | Structured classification (`input` + ordered questions) |

- **Model types & adapters** — models declare `llm`, `embedding`, `decision`, `stt`, `tts`, or `image` and are reachable only on their matching endpoint. Providers map to adapters (OpenAI, OpenRouter, DashScope, TypeSafe, TokenPlan) with customizable per-capability paths.
- **Health, priority & pools** — routes sort by `{health, priority}`; degraded credentials sink until recovery. Routes can mount a single key or a reusable provider key pool with per-request rotation and per-key circuit breakers and rate/concurrency buckets.
- **Failover & throttling** — auth/billing errors (`401`/`402`/`403`) disable the credential and fail over; timeouts and first-token timeouts fall back immediately. Subject limits (RPM/concurrency) protect TokenGate; provider limits (`max_rpm`, `max_concurrent`, `max_concurrent_per_user`) protect upstream keys.

## SmartRouter (`"model": "router"`)

- **Layered decision engine** — classifies requests across configurable use cases (13 built-in specialty presets covering fast chat, writing, presentations, coding implement/arch/audit, finance/data, research, computer use, 3D, vision extraction, ETL, and translation):
  0. **Session pins & tool loops** keep cache affinity unless a new capability breaks the pin.
  1. **Deterministic layer** filters by capabilities/context, applies priority rules (`force_use_case` / `restrict_use_cases` by limit profile, service, user, token range, flags, agent, or regex), and takes the fast path on trivial prompts.
  2. **On-demand classifier** runs only when 2+ use cases remain ambiguous and a `decision_model_id` is configured.
  3. **Effort-tier ranking** picks the cheapest healthy destination (or strongest on `critical_accuracy` / `quality_first`) with automatic fallback chains.
- **Access & accounting** — enabled globally and controlled with tri-state access (`inherit` / `allow` / `deny`) per limit profile, member, and service. Classifier calls are billed separately (`router_decision` logs) and net savings are tracked honestly against an optional baseline model.
- **Config versions & Shadow A/B** — exactly one version serves live traffic (`Default`); candidates can be cloned, edited, diffed, archived, promoted, or run asynchronously in **Shadow** mode (`router_shadow_evaluations`) at a configurable sample rate without touching client responses, latency, or billing.

## Cache, Prompts & Budgets

- **Sticky routing & session keys** — routes stick per session (`x-session-id` / `prompt_cache_key`, default 15 min TTL) to preserve upstream prompt caches.
- **Response cache & prompt optimizer** — identical non-streaming payloads hit an in-process ETS `ResponseCache` at `$0` cost. Chat payloads run through deterministic prompt optimization (system-message hoist/dedup, lazy cleanup, reasoning block stripping, history/image trimming) and optional per-model or per-binding `effort_default` / `effort_override`.
- **Budgets & top-ups** — monthly spend caps live on **Limit profiles** and **Services** (unless `unlimited_spend` is set). One-shot expiring **top-ups** drain in soonest-expiry order after the monthly cap.
- **Cost attribution** — prefers upstream-reported cost, falling back to per-route pricing (or a character-based token estimate when usage is omitted). Returns `X-Tokengate-Cost` and `usage.cost_usd` (including SSE tail frames).

## Admin Console (LiveView)

| Section | Routes | What it covers |
|---|---|---|
| Dashboard | `/dashboard` | Personal consumption, period selector, API key management, supervised-services shortcut |
| Analytics | `/stats` (`+ /overview`, `/models`, `/providers`, `/agents`, `/services`, `/profiles`, `/users`, `/router`), `/calculator` | Live pulse, period comparisons (`today` / `yesterday` / `week` / `30d`), router savings & shadow A/B metrics, CSV exports (`/stats/export`), cost simulator |
| Catalog | `/catalog/{router,models,providers,labs}` | SmartRouter configs/rules/dry-run/live/versions, model aliases & routes, providers/credentials/limits, labs catalog (models.dev + custom) |
| Access | `/access/{users,services}` | Users, suspension, impersonation, machine services, API keys, service supervisors |
| Budget | `/budget/{profiles,topups}` | Limit profiles, member limits & model/router grants, credit top-ups |
| Supervised | `/services/supervised` | Read-only service analytics scoped by `service_supervisors` |
| Operations | `/operations/{monitoring,audit,observability,notifications,maintenance}` | Live request feed, append-only audit log + CSV export, OTLP/JSON webhooks (Oban), Telegram alerts, retention & cache reset |

## Security & Architecture

- **Hot path on ETS** — auth, routing, circuit breakers, limits, budgets, and response cache read from ETS/atomics; Postgres writes happen asynchronously via Oban and background workers.
- **Partitioned storage** — `request_logs` uses daily RANGE partitions (90-day default retention, metadata only — prompts/completions are never stored) backed by an hourly rollup (`request_metrics_hourly`); `audit_logs` uses monthly append-only partitions (triggers reject `UPDATE`/`DELETE`).
- **Session & API auth** — bcrypt login with dual-bucket rate limiting, optional domain-restricted Google OAuth, revocable cookies (`users.session_version`) with idle + absolute lifetime caps, SHA-256 hashed 192-bit API keys, pre-auth bearer validation before body parsing, strict CSP, and formula-safe CSV exports.
- **First run** — `/onboarding` creates the first global admin under an advisory lock and self-disables once any user exists (or bootstrap via `TOKENGATE_ADMIN_PASSWORD`).
- **Operational notes** — provider API keys in `provider_credentials.api_key_encrypted` are stored as-is; Postgres TLS uses `verify: :verify_none` unless `ECTO_SSL_VERIFY=true`.

## Quick Start

Requires **Elixir 1.15+** and **PostgreSQL** (`postgres:postgres@localhost/tokengate_dev` by default).

```bash
git clone https://github.com/alvarolizama/tokengate.git
cd tokengate
mix setup          # deps -> DB create/migrate -> assets -> local admin seed
mix phx.server
```

Local dev admin: `admin@tokengate.local` / `tokengate-admin-secret-1` (override with `TOKENGATE_ADMIN_EMAIL` / `TOKENGATE_ADMIN_PASSWORD`).

Optional 31-day demo dataset (`@demo.tokengate` users, synthetic traffic, rollups):

```bash
mix ecto.demo
```

Using the proxy from an OpenAI client:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000/v1", api_key="tg-...")
resp = client.chat.completions.create(
    model="router",  # or any configured model alias
    messages=[{"role": "user", "content": "Hello"}],
)
```

## Configuration & Docker

Copy `.env.example` for full variable documentation. Required in production:

- `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `WEBHOOK_SECRET`, `SESSION_SIGNING_SALT`, `SESSION_ENCRYPTION_SALT`

Common optional vars: `PORT` (`4000`), `POOL_SIZE` (`10`), `MAX_CONNECTIONS` (`2048`), `PHX_SCHEME` / `PHX_PORT`, `CHECK_ORIGINS`, `TRUST_PROXY_HEADERS`, `ECTO_SSL` / `ECTO_SSL_VERIFY`, `TOKENGATE_ADMIN_EMAIL` / `TOKENGATE_ADMIN_PASSWORD`, `GOOGLE_OAUTH_*`, `TELEGRAM_BOT_TOKEN`, `PROXY_RECEIVE_TIMEOUT_MS`, `FIRST_TOKEN_TIMEOUT_MS`, `STREAM_IDLE_TIMEOUT_MS`, `CIRCUIT_BREAKER_*`, `ROUTING_SLOW_*`.

```bash
docker build -t tokengate .
docker run -p 4000:4000 --env-file .env tokengate
```

- Health check endpoint: `GET /health` (DB-free `200`, use this instead of `/`).
- Plain HTTP behind a VPN/LAN: build with `--build-arg DISABLE_FORCE_SSL=1` and set `PHX_SCHEME=http`.
- Maintenance Mix / release tasks: `mix tokengate.rollup.backfill` (`bin/rollup-backfill`), `mix tokengate.counters {backfill|reconcile}`, `mix tokengate.labs.snapshot`.

## Tests & Gates

```bash
mix precommit       # compile --warnings-as-errors, deps.unlock --unused, deps.audit, hex.audit, format, gettext.extract --check-up-to-date, test
mix test.parallel   # partitioned parallel test runner
```

## Tech Stack & License

Phoenix 1.8 + LiveView · Bandit · Ecto / PostgreSQL (RANGE partitions) · Finch · Req · Oban · Tailwind CSS v4 + daisyUI · esbuild · bcrypt_elixir

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Álvaro Lizama.
