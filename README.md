<div align="center">

<img src="docs/headers/tokengate-logo.png" width="96" height="96" alt="TokenGate" />

# TokenGate

**Self-hosted, OpenAI-compatible LLM API gateway built with Elixir, Phoenix LiveView, and PostgreSQL.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-9FE88D.svg)](./mix.exs)
[![Elixir](https://img.shields.io/badge/Elixir-1.15+-4B275F?logo=elixir&logoColor=white)](https://elixir.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8_LiveView-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-partitioned-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)

</div>

TokenGate sits between your apps or agents and your model providers. Clients use standard OpenAI SDKs (`base_url` + `api_key`), while TokenGate handles routing, credential pools, budgets, caching, SmartRouter selection, FinOps unit economics, and telemetry from one console.

UI ships in **English** and **Spanish** (`users.locale`, English by default).

## Proxy Capabilities (`/v1`)

- **OpenAI-compatible endpoints** — models discovery, streaming/non-streaming chat completions (including `"model": "router"`), embeddings, speech-to-text, text-to-speech, image generation, and structured `/v1/decisions` classification.
- **Model types & provider adapters** — models declare `llm`, `embedding`, `decision`, `stt`, `tts`, or `image`; providers map to OpenAI, OpenRouter, DashScope, TypeSafe, or TokenPlan adapters with customizable per-capability paths.
- **Health, priority & key pools** — routes sort by `{health, priority}` with single keys or reusable key pools (per-request rotation, circuit breakers, RPM and concurrency buckets).
- **Failover & throttling** — auth/billing errors (`401`/`402`/`403`) disable credentials and fail over; timeouts and first-token timeouts fall back immediately while protecting both TokenGate and upstream provider limits.

## SmartRouter (`"model": "router"`)

- **Layered decision engine** — routes requests across configurable use cases (13 built-in specialty presets):
  0. **Session pins & tool loops** preserve cache affinity unless a new capability breaks the pin.
  1. **Deterministic layer** filters by capabilities/context, applies priority rules (profile, service, user, token range, flags, agent, regex), and fast-paths trivial prompts.
  2. **On-demand classifier** runs only when 2+ use cases remain ambiguous.
  3. **Effort-tier ranking** picks the cheapest healthy destination (or strongest on critical accuracy) with automatic fallback chains.
- **Access & honest accounting** — tri-state access (`inherit` / `allow` / `deny`) per limit profile, member, and service; classifier calls are billed separately (`router_decision`) and net savings are tracked against an optional baseline model.
- **Config versions & Shadow A/B** — clone, edit, diff, archive, promote, or run candidate configs asynchronously in Shadow mode at a configurable sample rate without affecting client responses or billing.

## Cache, Prompts & Budgets

- **Sticky routing & response cache** — routes stick per session (`x-session-id` / `prompt_cache_key`) for upstream prompt caches, while identical non-streaming payloads hit an in-process ETS `ResponseCache` at `$0` cost.
- **Prompt optimizer & effort policy** — deterministic system-message hoist/dedup, reasoning block stripping, history/image trimming, and per-model or per-binding effort policies.
- **Budgets & top-ups** — monthly spend caps on **Limit profiles** and **Services** (or `unlimited_spend`), plus one-shot expiring **top-ups** drained in soonest-expiry order.
- **Cost attribution** — prefers upstream-reported cost with per-route pricing fallback; returns `X-Tokengate-Cost` and `usage.cost_usd`.

## Console Features

- **Personal Dashboard** — individual consumption metrics, period comparisons, `$/req` & cache hit visibility, API key management, and supervised-services shortcut.
- **FinOps & Unit Economics** — separated **Users vs. Services** spend and request accounting (`$/req`, `$/1M effective tokens`, `out/in` ratio, cost per active user/service), spend & waste anatomy (reasoning/thinking tax, error waste, router classifier overhead), dual cache efficiency (upstream prompt cache vs. `$0` local response cache), capability mix (`chat`, `embeddings`, `audio`, `images`), top-ups vs. monthly quota attribution, interactive efficiency outlier maps, and CSV exports.
- **Analytics & Simulator** — live pulse, period overview (`today` / `yesterday` / `week` / `30d`), model/provider/agent/profile/user rankings, SmartRouter ROI & Shadow A/B metrics, and cost simulator.
- **Per-Service & Supervised Views** — consolidated service overview, live logs, read-only supervisor console, and a dedicated per-service **FinOps** view (API-key filterable, burn rate, cap pacing, waste anatomy, and per-key/per-model unit economics).
- **Catalog, Access & Operations** — SmartRouter rules/versions/dry-run, model aliases & routes, providers/credentials/labs catalog, user & machine service management, limit profiles & top-ups, live monitoring, append-only audit logs, OTLP/JSON webhooks, Telegram alerts, and retention/cache maintenance.

## Security & Architecture

- **Hot path on ETS** — auth, routing, circuit breakers, limits, budgets, and response cache read from ETS/atomics; Postgres writes run asynchronously via Oban.
- **Partitioned storage** — `request_logs` uses daily RANGE partitions (90-day default retention, metadata only — never prompt/completion bodies) backed by hourly rollups (`request_metrics_hourly`); `audit_logs` uses monthly append-only partitions.
- **Auth & hardening** — bcrypt login with dual-bucket rate limiting, optional domain-restricted Google OAuth, revocable sessions, SHA-256 hashed 192-bit API keys, pre-auth bearer validation, strict CSP, and formula-safe CSV exports.

## Quick Start

Requires **Elixir 1.15+** and **PostgreSQL** (`postgres:postgres@localhost/tokengate_dev` by default).

```bash
git clone https://github.com/alvarolizama/tokengate.git
cd tokengate
mix setup          # deps -> DB create/migrate -> assets -> local admin seed
mix phx.server
```

Local dev admin: `admin@tokengate.local` / `tokengate-admin-secret-1` (override via `TOKENGATE_ADMIN_EMAIL` / `TOKENGATE_ADMIN_PASSWORD`). Optional 31-day synthetic demo dataset: `mix ecto.demo`.

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000/v1", api_key="tg-...")
resp = client.chat.completions.create(
    model="router",  # or any configured model alias
    messages=[{"role": "user", "content": "Hello"}],
)
```

## Configuration & Docker

Copy `.env.example` for full documentation. Required in production: `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `WEBHOOK_SECRET`, `SESSION_SIGNING_SALT`, `SESSION_ENCRYPTION_SALT`.

```bash
docker build -t tokengate .
docker run -p 4000:4000 --env-file .env tokengate
```

- Health check endpoint: `GET /health` (DB-free `200`).
- Plain HTTP behind a VPN/LAN: build with `--build-arg DISABLE_FORCE_SSL=1` and set `PHX_SCHEME=http`.
- Maintenance tasks: `mix tokengate.rollup.backfill` (`bin/rollup-backfill`), `mix tokengate.counters {backfill|reconcile}`, `mix tokengate.labs.snapshot`.

## Tests & Gates

```bash
mix precommit       # compile --warnings-as-errors, deps.unlock --unused, deps.audit, hex.audit, format, gettext.extract --check-up-to-date, test
mix test.parallel   # partitioned parallel test runner
```

## Tech Stack & License

Phoenix 1.8 + LiveView · Bandit · Ecto / PostgreSQL (RANGE partitions) · Finch · Req · Oban · Tailwind CSS v4 + daisyUI · esbuild · bcrypt_elixir

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Álvaro Lizama.
