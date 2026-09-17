<div align="center">

<img src="docs/headers/tokengate-logo.png" width="96" height="96" alt="TokenGate" />

# TokenGate

### One gate in front of every model. Routing, budgets and cache intelligence in between.

### OpenAI-compatible LLM API gateway

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-9FE88D.svg)](./mix.exs)
[![Elixir](https://img.shields.io/badge/Elixir-1.18+-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8_LiveView-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-partitioned-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)

</div>

## What is TokenGate

TokenGate sits between your agents/apps and the model providers. Clients call TokenGate
with a TokenGate API key using the **OpenAI SDK unchanged** (just base URL + key);
TokenGate routes each request to the best provider credential — with credit
subscriptions, rate limits, circuit breakers, prompt-cache intelligence and full cost
accounting in between.

Think "LiteLLM, but as an Elixir app with a real admin UI".

## Routing

- **OpenAI-compatible proxy API** — `POST /v1/chat/completions` (streaming SSE +
  non-streaming), `POST /v1/embeddings`, `GET /v1/models`.
- **Model aliases + type routing** — clients ask for an alias (`gpt-4o`); the alias maps
  to one or more provider credentials with `model_type` (`llm`/`embedding`) routing to
  the right endpoint. Switching backends is an admin operation, not a client deploy.
- **Health + priority routing** — credentials ordered by configured priority, with slow
  ones sinking below healthy ones until they recover. Billing surface (subscription vs
  pay-per-token) does not rank candidates: order is priority alone.
- **Fallback matrix + circuit breaker** — auth errors (401/402/403) disable the
  credential and fall back; timeouts and first-token timeouts fall back immediately;
  fast errors (5xx/429) retry before moving on. Per-credential breaker with configurable
  threshold/cooldown; included credentials tolerate 429s with a soft degrade. Every
  upstream attempt of one client request carries the same generated `Idempotency-Key`.
- **FIFO queue** for saturated included credentials — requests queue (tiered timeouts)
  instead of immediately falling back to pay-per-token, maximizing subscription use.
- **Two-gate throttling** — per-member limits (RPM, concurrency) protect TokenGate;
  per-provider limits (`max_rpm`, `max_concurrent`, `max_concurrent_per_user`)
  protect the upstream keys — every credential of a provider inherits them.

## Cache intelligence

- **Sticky sessions** — an API key sticks to the same credential to preserve prompt
  caches, with per-provider TTL overrides. Every outbound request also carries an
  `x-session-affinity` header so providers with automatic prefix caching group a
  session's requests onto the replica holding the cached prefix.
- **Conversation session key** — the gateway derives a per-conversation key
  (client-provided `session_id` / `prompt_cache_key`, or hashed from the conversation
  opening) for cache-affinity routing and per-conversation cache-hit observability.
  It travels upstream as `prompt_cache_key` (body) and `x-session-id` /
  `x-session-affinity` (headers); the OpenRouter-style `session_id` body field is
  never sent, so no upstream is handed a field it may reject.
- **Local response cache** — identical requests (same model + normalized payload) are
  served from a local cache without touching the upstream: faster answers, $0 cost.
- **Prompt optimizer** — every chat completion gets system messages hoisted and deduped
  (`stable_prefix`) and long/repeated tool-output messages trimmed (`lazy_cleanup`).
  Pure, deterministic, always on for LLMs. Multi-turn histories get reasoning blocks
  stripped before replay.
- **Usage normalization** — OpenAI-compatible usage is normalized into
  `prompt_tokens` / `completion_tokens` / `cache_read_tokens` / `cache_creation_tokens`
  (OpenRouter cache-write normalization included), priced separately at cache rates.

## Credits & budgets

- **Credit subscriptions** — a subscription grants `units` of credit per cycle
  (1 credit = $1): monthly with a cut-off day (with optional rollover % and cap) or a
  one-shot **top-up**. Group defaults (one sub shared by every member of the group) and
  direct user subs/top-ups, drained group-default first then direct credit, earliest
  expiry first. Recurring subs and top-ups have **separate admin pages** (`/credit/subscriptions`
  and `/credit/topups`); a subscription can be deactivated (stops granting until
  reactivated), and a top-up can also be **revoked** (deleted) or deactivated — the table
  shows how much of the top-up was consumed and, once the remaining balance hits 0 (drained)
  or it expires, it auto-archives (toggle to reveal).
- **Subjects without any applicable subscription are unlimited** (tier 3) — shown as
  "Ilimitado", not "no credit".
- **Daily spending cap per credential** — once reached, the router skips it until the
  next UTC day.
- **Global daily kill-switch** — instance-wide USD cap in Maintenance; once total spend
  reaches it, all proxy requests are rejected until 00:00 UTC. Per-user daily cap with
  exclusion lists evaluated before the global one.
- **Cost tracking** — the provider-reported usage cost is recorded per request and
  returned in the `X-Tokengate-Cost` header (LiteLLM upstreams via
  `x-litellm-response-cost`; Surplus Intelligence via `usage.buyer_cost_micro` or
  `x-si-buyer-cost-micro`, both micro-USD). No upstream cost → $0 recorded, no phantom estimates.

## Admin & dashboards (LiveView)

| Page | What it does |
|---|---|
| `/dashboard` | Personal live consumption, period selector, API key with rotate/revoke |
| `/stats` | Analytics hub — live pulse + tabs: overview, models, services, groups, users, credits. Role-scoped, prev-period deltas, CSV export. Hourly rollup (`request_metrics_hourly`) keeps period switching fast |
| `/logs` | Live request log, filters, in-flight requests, CSV export |
| `/calculator` | Real provider spend vs estimated cost with custom pricing |
| `/access/services` | Machine-to-machine API keys with their own budget/limits/grants, plus supervisor assignment |
| `/services/supervised` (+ `/:service_id`) | Read-only view for service supervisors: summary per supervised service (30d spend, requests, tokens, errors, latency, key status, granted models) and full per-service stats (period selector, daily usage per model, per-model breakdown, status classes, recent requests, roster). Access comes from a live `service_supervisors` row — no role grants it, and removing the row revokes it immediately |
| `/catalog/providers` | Provider CRUD, multiple credentials each, per-provider sticky TTL |
| `/catalog/models` | Alias CRUD — providers by priority, `billing_mode`, exclusive scope |
| `/access/groups` (+ members) | Group defaults, per-member extras and grants, observability webhooks |
| `/access/users` | User CRUD, suspend, impersonation, per-user stats, credit column |
| `/credit/subscriptions` | Recurring (monthly) credit subscriptions — group defaults + direct user subs; deactivate/reactivate |
| `/credit/topups` | One-shot top-ups per user: consumed vs granted, deactivate (revokes remaining balance) / revoke, auto-archived when drained or expired |
| `/operations/observability` | OTLP/JSON webhook destinations (HMAC-signed, delivered via Oban) |
| `/operations/maintenance` | Config overview, danger zone, global daily cap kill-switch |

## Platform

- **Hot path on ETS** — auth, limits, budgets, routing and metrics read from ETS only;
  Postgres is written asynchronously. Named tables degrade gracefully when absent.
- **Postgres** — daily RANGE-partitioned `request_logs` (append-heavy by design),
  hourly metrics rollup with worker + backfill, audit logs, Oban jobs.
- **Auth** — email/password (Bcrypt) + optional Google OAuth with domain-restricted
  auto-registration; sliding-expiration sessions; per-user timezone bucketing.

## Quick start

```bash
git clone git@github.com:alvarolizama/tokengate.git && cd tokengate
mix setup        # deps → create DB → migrate → assets → seed admin
mix phx.server
```

Visit [localhost:4000](http://localhost:4000) and sign in with the seeded admin:

| | Default | Override with |
| --- | --- | --- |
| Email | `admin@tokengate.local` | `TOKENGATE_ADMIN_EMAIL` |
| Password | `tokengate-admin-secret-1` | `TOKENGATE_ADMIN_PASSWORD` |

Then: create a **provider** with a credential → create a **model** alias and assign the
provider → grant the alias to a **group** → your member API key is already on your
dashboard. You can proxy a request in ~5 minutes.

### Demo dataset (a month of usage)

To exercise every screen with real data instead of an empty instance:

```bash
mix ecto.demo    # priv/repo/demo_seeds.exs — idempotent, safe to re-run
```

Seeds 31 days of synthetic traffic (~7.5k request logs) plus the full surface
around it: 12 demo users and 4 groups (active subscription, one with rollover,
one paused, one deliberately over-budget), 3 machine services (own subscription,
one-shot, unlimited) with supervisors, 2 custom providers + credentials in
`error`/`disabled` states, 11 models with market + manual pricing,
`prompt_cache_enabled`, exclusive routes (member / group / service), credit
subscriptions and top-ups (active, drained, expired), observability webhooks,
a custom lab, and a month of audit entries. The hourly metrics rollup is
rebuilt for the whole range.

Everything it creates is marked (users at `@demo.tokengate`, fixed group/lab
names, `sk-demo-` credential keys) and wiped on the next run — operator data is
never touched. Re-running produces identical row counts. The script prints the
demo API keys at the end:

| | Value |
| --- | --- |
| Demo users | `<name>@demo.tokengate` |
| Password | `DemoPassw0rd!2026` |
| Admin dashboard | the seeded admin also gets a demo membership |

`mix run priv/repo/demo_verify.exs` re-checks the dataset by calling the same
context functions the LiveViews use (one line per screen).

## Using the proxy

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000/v1",
    api_key="tg-…",   # TokenGate API key (group member or service)
)

resp = client.chat.completions.create(
    model="gpt-4o",   # the TokenGate alias, not the provider's model id
    messages=[{"role": "user", "content": "Hello"}],
)
```

## Configuration

**Required in production** (boot fails without them):

| Var | Purpose |
| --- | --- |
| `DATABASE_URL` | Postgres connection string |
| `SECRET_KEY_BASE` | Phoenix secret (`mix phx.gen.secret`) |
| `PHX_HOST` | Public host |
| `WEBHOOK_SECRET` | HMAC key for observability webhook deliveries |
| `SESSION_SIGNING_SALT` / `SESSION_ENCRYPTION_SALT` | Session cookie salts (`mix phx.gen.secret 32`) |

**Common optional knobs:**

| Var | Default | What it tunes |
| --- | --- | --- |
| `PORT` | `4000` | HTTP port |
| `POOL_SIZE` | `10` | DB connection pool |
| `SESSION_MAX_AGE_SECONDS` | `31536000` | Idle session lifetime (sliding) |
| `PROXY_RECEIVE_TIMEOUT_MS` | `60000` | Upstream read timeout (per-credential override) |
| `FIRST_TOKEN_TIMEOUT_MS` | `30000` | Streaming: max wait for first chunk |
| `CIRCUIT_BREAKER_THRESHOLD` | `3` | Failures before a breaker opens |
| `CIRCUIT_BREAKER_COOLDOWN_MS` | `30000` | Breaker open duration |
| `ROUTING_SLOW_THRESHOLD_MS` | `30000` | Latency that marks a credential degraded |
| `ECTO_SSL` / `ECTO_SSL_VERIFY` | on / off | DB SSL and cert verification |
| `PHX_SCHEME` / `PHX_PORT` | `https` / `443` | URL generation (set `http` behind a VPN proxy) |
| `GOOGLE_OAUTH_CLIENT_ID` / `SECRET` | unset | Enable Google sign-in |
| `GOOGLE_OAUTH_ALLOWED_DOMAINS` | unset | Domains allowed to auto-register |
| `DNS_CLUSTER_QUERY` | unset | Node clustering DNS query |

## Production (Docker)

Multi-stage **Dockerfile** included: prebuilt hexpm Elixir image → slim Debian runtime,
non-root `app` user, port `4000`. The entrypoint applies migrations and seeds the admin
before boot; `SKIP_MIGRATIONS=1` bypasses.

```bash
docker build -t tokengate .
docker run -p 4000:4000 --env-file .env tokengate
```

> ⚠️ **Migrations on partitioned tables:** `CREATE INDEX` on `request_logs` cannot use
> `CONCURRENTLY` (Postgres limitation). On a large existing table, run migrations in a
> maintenance window.

## Tech stack

Phoenix 1.8 + LiveView · Bandit · Ecto/Postgres (RANGE partitions) · Finch (upstream
HTTP/SSE) · Req (outbound) · Oban · Tailwind CSS v4 + daisyUI (dim) · esbuild ·
bcrypt_elixir

## Development

```bash
mix precommit   # compile --warnings-as-errors → deps.unlock --unused → deps.audit → format → test
```

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Álvaro Lizama.
The license covers the whole repository: the Phoenix server, the admin UI and
the Docker production image. Third-party dependencies keep their own licenses.
