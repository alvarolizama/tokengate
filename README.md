<p align="center">
  <img src="priv/static/images/logo.svg" width="120" alt="TokenGate">
</p>

<h1 align="center">TokenGate</h1>

<p align="center">
  An OpenAI-compatible <strong>LLM API gateway</strong> built with <strong>Phoenix 1.8 + LiveView</strong>.
  It sits between your agents/apps and the model providers: clients call TokenGate with a TokenGate
  API key, and TokenGate routes each request to the best provider credential — with budgets,
  rate limits, circuit breakers, and full cost accounting in between.
</p>

<p align="center">
  Think "LiteLLM, but as an Elixir app with a real admin UI".
</p>

<img src="docs/screenshots/dashboard.png" alt="TokenGate dashboard" width="100%">

> **Note:** the admin UI language is Spanish; the proxy API and this README are English.

## Features

### Gateway

- **OpenAI-compatible proxy API** — `POST /v1/chat/completions` (streaming SSE + non-streaming), `POST /v1/embeddings`, `POST /v1/rerank`, `GET /v1/models`. Keep using the OpenAI SDK; just change the base URL and the key.
- **Model aliases + type routing** — clients ask for an alias (e.g. `gpt-4o`); TokenGate maps it to one or more provider credentials. Each alias has a `model_type` (`llm`, `embedding`, `rerank`) that routes to the correct endpoint. Switching backends is an admin operation, not a client deploy.
- **Tiered priority routing + sticky sessions** — providers are ordered by priority and grouped into tiers: healthy subscriptions (`included`) first, then degraded subscriptions, then healthy pay-per-token, then degraded pay-per-token. An API key sticks to the same credential to preserve prompt caches, with per-provider sticky TTL overrides (configurable in seconds). A slow-but-answering credential is marked "degraded" and sinks to the bottom of its tier until it recovers.
- **FIFO queue for saturated included credentials** — when a subscription credential hits its concurrency limit, requests queue FIFO (with tiered timeouts) instead of immediately falling back to pay-per-token, maximizing subscription utilization.
- **Fallback matrix + circuit breaker** — auth errors (401/402/403) disable the credential and fall back; timeouts and first-token timeouts fall back immediately; fast errors (5xx/429) retry before moving on. Per-credential circuit breaker with configurable threshold/cooldown. Included (subscription) credentials tolerate 429s with a soft degrade instead of tripping the breaker. Every upstream attempt of one client request carries the same generated `Idempotency-Key` header (retries and provider fallbacks included), so providers that processed a lost response can deduplicate the replay.
- **Two-gate throttling** — per-user limits (team defaults + per-member overrides: RPM, concurrency) protect TokenGate; per-credential limits (`max_rpm`, `max_concurrent`, `max_concurrent_per_user`) protect the upstream key.
- **Monthly USD budgets** — per team member (team default + member extra) and per service. ETS hot counters checked pre-flight; Postgres `request_logs` is the durable truth.
- **Daily spending limit per credential** — a provider credential can carry a daily USD cap; once reached, the router skips it and fails over to the next credential until the next UTC day. Live spend/limit indicator on the Models page.
- **Global daily spending cap (kill-switch)** — instance-wide daily USD limit in Settings; once total spend across all members and credentials reaches the cap, all proxy requests are rejected until 00:00 UTC. `nil` means unlimited (default).
- **Cost tracking** — the provider-reported `usage.cost` is recorded per request and returned in the `X-Tokengate-Cost` response header. LiteLLM upstreams are supported via the `x-litellm-response-cost` header. Subscription providers (`billing_mode: included`) count as $0. When the upstream doesn't report a cost, TokenGate records $0 (honest fallback, no phantom estimates).
- **Pre-flight prompt optimization** — system messages are hoisted to the front and deduped (`stable_prefix`); long or repeated tool-output messages are trimmed and collapsed (`lazy_cleanup`). Both passes are pure and side-effect-free.
- **Reasoning/thinking flag parsing** — normalizes `reasoning_effort` (OpenAI), `reasoning` (new OpenAI), and `thinking` (Anthropic/GLM) into a unified `{think, effort}` tuple across providers.
- **Agent identification headers** (OpenRouter-style) — `X-Agent-Type`, `X-Title`, `HTTP-Referer`, `User-Agent` feed metrics and limits.

### Admin UI (LiveView)

- **Personal dashboard** (`/dashboard`) — every user sees their own live consumption (requests, cost, tokens, tokens/sec), period selector (today/7d/30d/90d), their API key with rotate/revoke, and the model catalog available to them with usage-tier badges.
- **Stats** (`/dashboard/stats`) — drill-downs by model, team, service, and member; scoped by role (admin sees org-wide, managers their teams, users themselves). Period comparison with vs-yesterday deltas, daily sparkline charts, sortable breakdown tables, and CSV export.
- **Monitor** (`/dashboard/monitor`) — trading-terminal view: one ticket per model alias with 60-minute sparklines, RPM, error rate, cost, in-flight requests, and per-credential drill-down with circuit-breaker state. "Por API Key" tab with per-credential sparklines and in-flight users. KPIs from last-hour to today with vs-yesterday deltas.
- **Logs** (`/dashboard/logs`) — live request log with filters, in-flight requests merged into the main table, and CSV export (30d / 90d).
- **Credits** (`/dashboard/credits`) — every member's spend against their effective budget, live from the ETS counters, with progress bars.
- **Calculator** (`/dashboard/calculator`) — compare real provider spend vs estimated cost using custom pricing parameters (input/output price per million tokens). Period and model selector. Uses the same cost source as Stats for consistency.
- **Teams** (`/dashboard/teams`) — team CRUD with default budgets/limits, per-team model-alias grants, and per-team observability webhook destinations. Dynamic card grid (1/2/3 cols based on team count).
- **Team members** (`/dashboard/teams/:id/members`) — add members by email (auto-generates their API key), per-member extras: extra budget, concurrency, RPM, and individual model-alias grants with optional per-model daily budget. Search filter by name and email.
- **Services** (`/dashboard/services`) — machine-to-machine API keys (not tied to a user) with their own monthly budget, concurrency, RPM, and model grants. **Supervisors** get a read-only view (`/dashboard/services/supervised`).
- **Providers** (`/dashboard/providers`) — provider CRUD with multiple credentials each (encrypted key, rate/concurrency limits, status, icon toggle). Per-provider sticky TTL override in seconds. Provider health surfaced in sidebar with failing credentials highlighted.
- **Models** (`/dashboard/models`) — model-alias CRUD; assign providers with priority, `billing_mode` (`pay_per_token` / `included`), `model_type` (`llm` / `embedding` / `rerank`), and exclusive scope (global / member / team).
- **Users** (`/dashboard/users`) — user CRUD, suspend/activate, password reset, per-user stats (`/dashboard/users/:user_id/stats`), **impersonation**, filter by today's spend, group by team, and sortable columns.
- **Settings** (`/dashboard/settings`) — read-only config overview plus a Danger Zone (reset request logs, sticky sessions, member extras). Global daily spending cap kill-switch lives here.

### Platform

- **Observability webhooks** — every request log is delivered to per-team destinations as an OTLP/JSON span, HMAC-signed (`X-Tokengate-Signature: sha256=…`), via Oban.
- **Hot path on ETS** — auth, limits, budgets, routing, and metrics read from ETS only; Postgres is written asynchronously (Oban workers). Named ETS tables degrade gracefully when absent (hot-reload safe).
- **Postgres** — teams, users, services, sha256-hashed API keys, providers, credentials, aliases, daily RANGE-partitioned `request_logs`, audit logs, Oban jobs. Provider ranking by failures + latency with tiers S/A/B/C/D.
- **Auth** — email/password (Bcrypt) plus optional Google OAuth (enabled when `GOOGLE_OAUTH_CLIENT_ID`/`SECRET` are set; auto-registration restricted by `GOOGLE_OAUTH_ALLOWED_DOMAINS`). Sliding-expiration session cookies (default 1 year idle).
- **Usage normalization** — OpenAI-compatible usage payloads are normalized into a unified internal shape (`prompt_tokens`, `completion_tokens`, `cache_read_tokens`, `cache_creation_tokens`). `prompt_tokens` keeps the provider's raw total (cached tokens included); `cache_read_tokens` is the cached subset, priced separately at the cache rate by the cost calculator.
- **Per-user timezone** — dashboard data is bucketed by each user's configured timezone; session-scoped timezone selector for LiveViews.

## Requirements

- **Elixir** `~> 1.15` (developed on 1.20.x / OTP 29) and **Erlang/OTP**
- **PostgreSQL**

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

Then, from the UI: create a **provider** with a credential → create a **model** alias and assign the provider → grant the alias to a **team** → your member API key is already on your dashboard. You can proxy a request in ~5 minutes.

## Using the proxy

Point any OpenAI-compatible client at TokenGate:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000/v1",
    api_key="tg-…",   # TokenGate API key (team member or service)
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
| `WEBHOOK_SECRET` | HMAC key for signing observability webhook deliveries |
| `SESSION_SIGNING_SALT` / `SESSION_ENCRYPTION_SALT` | Session cookie salts (`mix phx.gen.secret 32`) |

**Common optional knobs:**

| Var | Default | What it tunes |
| --- | --- | --- |
| `PORT` | `4000` | HTTP port (`4001` in the Docker image) |
| `POOL_SIZE` | `10` | DB connection pool |
| `SESSION_MAX_AGE_SECONDS` | `31536000` | Idle session lifetime (sliding, default 1 year) |
| `PROXY_RECEIVE_TIMEOUT_MS` | `60000` | Upstream read timeout (per-credential override available) |
| `FIRST_TOKEN_TIMEOUT_MS` | `30000` | Streaming: max wait for first chunk before fallback |
| `CIRCUIT_BREAKER_THRESHOLD` | `3` | Failures before a credential's breaker opens |
| `CIRCUIT_BREAKER_COOLDOWN_MS` | `30000` | Breaker open duration |
| `CIRCUIT_BREAKER_RATE_LIMIT_COOLDOWN_MS` | `20000` | Breaker duration after a 429 |
| `ROUTING_SLOW_THRESHOLD_MS` | `30000` | Latency that marks a credential "degraded" |
| `ROUTING_SLOW_PENALTY_MS` | `120000` | How long a degraded credential sinks in its tier |
| `ECTO_SSL` / `ECTO_SSL_VERIFY` | on / off | DB SSL and certificate verification |
| `PHX_SCHEME` / `PHX_PORT` | `https` / `443` | URL generation scheme/port (set `PHX_SCHEME=http` behind a plain-HTTP VPN) |
| `CHECK_ORIGINS` | unset | Extra allowed origins (multi-scheme deploys) |
| `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | unset | Enable Google sign-in |
| `GOOGLE_OAUTH_REDIRECT_URI` | derived | OAuth callback (defaults from `PHX_SCHEME`/`PHX_HOST`) |
| `GOOGLE_OAUTH_ALLOWED_DOMAINS` | unset | Comma-separated domains allowed to auto-register |
| `DNS_CLUSTER_QUERY` | unset | Node clustering DNS query |

## Production (Docker)

Multi-stage **Dockerfile** included: prebuilt hexpm Elixir image → slim Debian runtime, non-root `app` user, port `4001`. The entrypoint applies migrations and seeds the admin before boot; `SKIP_MIGRATIONS=1` bypasses.

```bash
docker build -t tokengate .
docker run -p 4001:4001 --env-file .env tokengate
```

- **`DISABLE_FORCE_SSL=1`** (default build ARG) — `force_ssl` is compile-time in Phoenix; the default image serves plain HTTP (VPN/reverse-proxy deploys). Rebuild with an empty value to re-enable TLS redirects.
- Oban runs a monthly cron (`0 0 1 * *`) that resets the monthly ETS budget counters on the 1st.

> ⚠️ **Migrations on partitioned tables:** `CREATE INDEX` on `request_logs` cannot use `CONCURRENTLY` (Postgres limitation). On a large existing table, run migrations in a maintenance window.

## Tech stack

Phoenix 1.8 + LiveView · Bandit · Ecto/Postgres · Finch (upstream HTTP/SSE) · Req (outbound) · Oban · Tailwind CSS v4 + esbuild · bcrypt_elixir · gettext

## Development

```bash
mix precommit   # compile --warnings-as-errors → deps.unlock --unused → deps.audit → format → test
```

## License

MIT
