<div align="center">

<img src="docs/headers/tokengate-logo.png" width="96" height="96" alt="TokenGate" />

# TokenGate

### One gate in front of every model. Routing, budgets and cache intelligence in between.

### OpenAI-compatible LLM API gateway

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-9FE88D.svg)](./mix.exs)
[![Elixir](https://img.shields.io/badge/Elixir-1.15+-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8_LiveView-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-partitioned-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)

</div>

## What is TokenGate

TokenGate sits between your agents/apps and the model providers. Clients call TokenGate
with a TokenGate API key using the **OpenAI SDK unchanged** (just base URL + key);
TokenGate routes each request to the best provider credential — with per-subject
budgets, rate limits, circuit breakers, prompt-cache intelligence and cost
accounting in between.

Think "LiteLLM, but as an Elixir app with a real admin UI".

The UI ships in **English by default** with an in-app **EN/ES** selector
(`users.locale`). Most strings are translated; a handful of legacy ones are still
Spanish-only.

## Screenshots

<div align="center">

| Login | Dashboard |
|:---:|:---:|
| <img src="docs/screenshots/login.png" width="420" alt="Sign-in" /> | <img src="docs/screenshots/dashboard.png" width="420" alt="Personal dashboard" /> |
| **Stats** | **Provider ranking** |
| <img src="docs/screenshots/stats.png" width="420" alt="Analytics hub" /> | <img src="docs/screenshots/providers.png" width="420" alt="Provider ranking with tiers" /> |
| **Monitoring** | **Top-ups** |
| <img src="docs/screenshots/monitoring.png" width="420" alt="Live request log" /> | <img src="docs/screenshots/topups.png" width="420" alt="One-shot credit top-ups" /> |

</div>

## Routing (proxy API)

The public surface is exactly these seven routes:

| Route | What it serves |
|---|---|
| `GET /v1/models` | Every model alias the presented key can reach, with `context_window` |
| `POST /v1/chat/completions` | Chat, streaming SSE and non-streaming |
| `POST /v1/embeddings` | Embeddings (non-streaming only) |
| `POST /v1/audio/transcriptions` | Speech-to-text passthrough (multipart forwarded byte-for-byte) |
| `POST /v1/audio/speech` | Text-to-speech passthrough (audio bytes back) |
| `POST /v1/images/generations` | Image generation passthrough |
| `POST /v1/decisions` | The decision surface, in the OpenAI Decisions shape (`input` + ordered questions) |

- **Model aliases + type routing** — clients ask for an alias (`gpt-4o`); it maps
  to one or more provider routes. The model's `model_type` selects the surface —
  `llm`, `embedding`, `decision`, `stt`, `tts`, `image` — and a model is only
  reachable from the endpoint of its type (`stt` only from
  `/v1/audio/transcriptions`, and so on). Switching backends is an admin
  operation, not a client deploy.
- **Health + priority routing** — candidates sort by `{health, priority}`: healthy
  credentials first, slow ones sinking below until they recover; within a level,
  `priority` ASC decides. Billing surface (subscription vs pay-per-token) does
  **not** rank candidates — order is priority alone.
- **Fallback + circuit breaker** — auth errors (401/402/403) permanently disable
  the credential and fall back; timeouts (and first-token timeouts) fall back
  immediately; other errors retry the provider before moving on. Per-credential
  breaker with configurable threshold/cooldown. Every upstream attempt of one
  client request carries the same generated `Idempotency-Key`.
- **Two-gate throttling** — per-subject limits (RPM, concurrency) protect
  TokenGate; per-provider limits (`max_rpm`, `max_concurrent`,
  `max_concurrent_per_user`) protect the upstream key — every credential of a
  provider inherits them, and the per-user gate is keyed by
  `{credential, api_key}` so one heavy user can't swallow a shared subscription.

## Cache intelligence

- **Sticky routing** — a key sticks to the same credential to preserve prompt
  caches, with per-route TTL overrides (default **15 min**).
- **Conversation session key** — the gateway derives a per-conversation key
  (client `x-session-id` header or `prompt_cache_key` body field, or hashed from
  the conversation opening) for cache-affinity routing and per-conversation
  cache-hit observability. It **never travels in the upstream body**: it goes out
  as the `x-session-id` header, plus an `x-session-affinity` hint for providers
  running automatic prefix caching.
- **Local response cache** — identical non-streaming requests (same key + model +
  canonical payload) are served from an in-process ETS cache without touching the
  upstream: faster answers, $0 cost — and the hit still answers with
  `X-Tokengate-Cost: 0` (`usage.cost_usd = 0` on chat), so the cost contract of a
  live answer never disappears. Requests with a captured raw body (multipart
  audio) and streaming requests are never cached.
- **Prompt optimizer** — every chat completion gets system messages hoisted and
  deduped and long/repeated tool-output messages trimmed. Pure, deterministic,
  always on for LLMs. Multi-turn histories get reasoning blocks stripped before
  replay.
- **Reasoning effort policy** — per model, from the model editor: an
  `effort_default` that replaces a client's `none`/`minimal` (a 400 on
  reasoning-mandatory upstreams like GLM 5.3) and an `effort_override` that
  wins over whatever the client sent. Unset means byte-identical passthrough.
  Every substitution is recorded in `request_logs.effort_applied` — Logs shows
  the intent (`none → low` badge) and the CSV export carries the column.
- **Usage normalization** — OpenAI-compatible usage is normalized into
  `prompt_tokens` / `completion_tokens` / `cache_read_tokens` /
  `cache_creation_tokens`, priced separately at cache rates.

## Budgets & credit

- **Limit profiles** (formerly "groups"/"subs") — the subject each member inherits
  a monthly spend cap from (`monthly_spend_limit_usd`), plus **service** caps of
  their own. `unlimited_spend` is the only path to unlimited.
- **Top-ups** — one-shot credit per **user or service**, with optional expiry.
  Consumed-vs-granted is measured against the request logs; a top-up can be
  deactivated/reactivated or revoked, and it's archived (not deleted) once drained
  or expired. Live in `/budget/topups`.
- **Draining order** — the monthly limit is spent first; once exhausted (or on a
  zero/absent limit) the top-up that **expires soonest** is drained.
- **Global daily kill-switch** — instance-wide per-UTC-day USD cap
  (`/budget/global`); once total spend reaches it, all proxy requests are rejected
  until 00:00 UTC. Users, limit profiles and services can be exempted.
- **Cost tracking** — the provider-reported usage cost is the single cost dimension,
  recorded per request and returned to the client: in the `X-Tokengate-Cost` header
  (LiteLLM upstreams via `x-litellm-response-cost`) and, on chat, in the
  response's `usage.cost_usd`. A stream commits its 200 before the cost is known, so the cost
  travels in the SSE — the upstream's own usage frame, or a closing usage frame
  TokenGate emits before `data: [DONE]` when the upstream sends none. No upstream
  cost → manual per-route pricing → `$0`; no phantom estimates.

## Admin console (LiveView)

| Page | What it does |
|---|---|
| `/dashboard` | Personal live consumption, period selector, the user's API keys with create/rename/rotate/revoke, supervised-services shortcut |
| `/stats` | Analytics hub — Live pulse + tabs: Overview, Providers (tier/score ranking), Models, Limit profiles, Users, Services. One period selector — **Today / This week / This month / 30 days / 90 days** — shared by the hub and every detail page, with the choice in the URL so it survives bookmarks and refresh; role-scoped, previous-period deltas, CSV export (`/stats/export`) |
| `/calculator` | Real provider spend vs an estimated cost from custom pricing (input/cache/output per M + cache-hit rate) |
| `/catalog/labs` | Labs catalog — read-only models.dev labs + operator **custom** labs (name, key, icon/logo) |
| `/catalog/providers` | Provider CRUD with multiple credentials each; per-provider operational limits; custom providers declare their capabilities (chat/decisions/embeddings/audio/image) and can override the upstream path per capability; billing surface label |
| `/catalog/models` | Model alias CRUD — provider routes by priority, exclusive scope, manual per-route pricing |
| `/access/services` | Machine services: own API keys, monthly cap + top-ups, supervisors, granted models |
| `/stats/services/:id` | Full analytics per service — KPIs, models served, hourly distribution — and the **per-API-key table**: requests, cost and tokens for **every key of the service, active or revoked** (revoked ones keep their badge), traffic that predates the keys lands as an *Unattributed* row, and the key selector scopes the whole report — KPIs, breakdown and log — to a single key |
| `/access/users` | User CRUD, suspend/activate, impersonation, per-user stats and spend limits |
| `/budget/profiles` (+ `/:id/members`) | Limit profiles — monthly cap, unlimited flag, membership, per-member RPM/concurrency extras and model grants |
| `/budget/topups` | One-shot top-ups per user/service: consumed vs granted, deactivate/reactivate, revoke, archived when drained/expired |
| `/budget/global` | Global daily cap kill-switch + exemptions |
| `/services/supervised` (+ `/:service_id`) | Read-only view for service supervisors — the same analytics as the service stats page (KPIs, models, per-API-key table, period selector), no role grants it; access comes from a live `service_supervisors` row (removing the row revokes it) |
| `/operations/monitoring` | Live request log, filters, in-flight requests, CSV export (`/stats/export?type=logs`) |
| `/operations/audit` | Admin audit log — actor (+ impersonator), action, entity, IP, redacted change set; filters, pagination, CSV export (`/operations/audit/export`) |
| `/operations/observability` | OTLP/JSON webhook destinations (HMAC-signed, delivered via Oban) |
| `/operations/notifications` | Telegram notifications — bot token (encrypted at rest, or env), events + severity/cooldown, quiet hours, linked chats, delivery log with manual resend |
| `/operations/maintenance` | Config overview + danger zone (reset logs, reset sticky sessions) |

## Security

What the app actually enforces today — no more, no less:

**Access control**

- **Cabinet session** — the session cookie is encrypted and signed, `http_only`,
  `same_site=Lax`, renewed on login (session-fixation guard) and **revocable**:
  `users.session_version` is bumped on suspension, on an admin password reset and
  on a self password change, so every cookie issued before is dead on the next
  request. `DashboardAuth` checks it on every HTTP request and `UserAuth` on every
  LiveView mount (sockets don't re-run plugs).
- **Two clocks** — `SESSION_MAX_AGE_SECONDS` (7 days, sliding: it measures
  *idle*) and `SESSION_ABSOLUTE_MAX_AGE_SECONDS` (30 days, fixed: it measures
  *life*). `renew: true` would otherwise make an active session immortal.
- **Suspension means suspension** — `users.status = "suspended"` cuts the login,
  the open dashboard session **and** the API key: the proxy auth path resolves the
  key's owner and rejects an inactive one with `401 invalid_api_key`.
- **Roles** — admin-only LiveViews and exports run behind `require_admin` (both a
  plug and an `on_mount`); the supervised-services area is granted by a live
  `service_supervisors` row, not by role. Impersonation is admin-only, audited
  start and stop, and the root admin can never be impersonated.
- **API keys** — 192 bits from `:crypto.strong_rand_bytes/1`, shown **once**,
  stored as SHA-256, revocable and rotatable individually; the auth cache
  invalidates by key, member, group or user on every write that matters.

**Perimeter**

- **Pre-auth on `/v1`** — a request without a well-formed `Authorization: Bearer`
  is rejected **before** the body is read, so an anonymous client can't push the
  10 MB body cap into memory nor spend a database lookup per bogus token (failed
  keys are deliberately never cached).
- **Login throttle with two buckets** — 10 attempts/min **per account** and 50/min
  **per source**. A failed batch against one account no longer locks everybody
  out. Behind a proxy, set `TRUST_PROXY_HEADERS=true` so the IP bucket measures the
  client (the last `X-Forwarded-For` hop) instead of the proxy.
- **Connection ceiling** — `MAX_CONNECTIONS` (2048 by default) caps the listener;
  ThousandIsland's default of 16384 is a memory hazard in a small container.
- **Browser hardening** — strict CSP (`script-src 'self'`, `frame-ancestors
  'none'`, `form-action 'self'`), `permissions-policy`, CSRF protection on the
  whole browser pipeline, and `force_ssl` + HSTS in production.
- **SQL** — zero raw SQL with interpolation; the only `fragment/1` calls are
  static aggregates.

**Data**

- **Audit log** — append-only at the database level (a trigger rejects `UPDATE` and
  `DELETE`), monthly partitions, actor + impersonator + IP + user agent + change
  set, on every privileged mutation.
- **Request log** — metadata only: tokens, cost, latency, status. **Prompts and
  completions are never stored.**
- **Exports** — one shared CSV writer with a formula-injection guard (`=`, `+`,
  `-`, `@`, tab, CR are prefixed), because `user_agent`, `origin` and
  `error_message` are client- or upstream-controlled text.

**Supply chain**

- `mix precommit` runs **both** audits: `deps.audit` (mix_audit → hex.pm) and
  `hex.audit` (EEF → osv.dev). They do not see the same things — trusting only the
  first is how the HTTP server sat 22 advisories behind.

**Known limitations** (deliberately listed, not hidden)

- Provider API keys are stored **as-is** in `provider_credentials.api_key_encrypted`
  — encryption at rest is pending (see the moduledoc of
  `Tokengate.Providers.Credential`). The column name is aspirational.
- Postgres TLS connects with `verify: :verify_none` by default; strict verification
  is opt-in with `ECTO_SSL_VERIFY=true`.
- `/onboarding` is open until the first user exists: bootstrap the admin with
  `TOKENGATE_ADMIN_PASSWORD` **before** exposing the instance.
- The login throttle has no account lockout or CAPTCHA; it bounds retries, it does
  not stop a patient distributed attempt.

## Platform

- **Hot path on ETS** — auth, limits, budgets, routing and metrics read from ETS/atomics
  only; Postgres is written asynchronously. Named tables degrade gracefully when absent.
- **Postgres** — daily RANGE-partitioned `request_logs` (append-heavy by design),
  monthly-partitioned **append-only** `audit_logs` (trigger rejects UPDATE/DELETE),
  hourly metrics rollup with worker + backfill, Oban jobs.
- **Auth** — email/password (Bcrypt, timing-safe on unknown emails) + optional
  Google OAuth with domain-restricted auto-registration; revocable sessions with
  sliding idle expiry plus an absolute lifetime cap; per-user timezone bucketing;
  admin impersonation.

## Quick start

```bash
git clone git@github.com:alvarolizama/tokengate.git && cd tokengate
mix setup        # deps → create DB → migrate → assets → seed admin + dev dataset
mix phx.server
```

Visit [localhost:4000](http://localhost:4000) and sign in with the seeded admin:

| | Default | Override with |
| --- | --- | --- |
| Email | `admin@tokengate.local` | `TOKENGATE_ADMIN_EMAIL` |
| Password | `tokengate-admin-secret-1` | `TOKENGATE_ADMIN_PASSWORD` |

Then: create a **provider** with a credential → create a **model** alias and assign the
provider → give a **limit profile** a monthly cap → your member API key is already on
your dashboard. You can proxy a request in ~5 minutes.

### Demo dataset (a month of usage)

To exercise every screen with real data instead of an empty instance:

```bash
mix ecto.demo    # priv/repo/demo_seeds.exs — idempotent, safe to re-run
```

Seeds 31 days of synthetic traffic (~7.7k request logs) plus the full surface
around it: 12 demo users and 4 limit profiles (one unlimited, one deliberately
over-budget), 3 machine services (own cap / one-shot top-up / unlimited) with
supervisors, 2 custom providers + credentials in `error`/`disabled` states,
11 models with manual pricing and exclusive routes (member / profile / service),
credit top-ups (active, drained, expired), observability webhooks, a custom lab,
and a month of audit entries. The hourly metrics rollup is rebuilt for the whole
range, and the top-ups are calibrated to the generated spend.

Everything it creates is marked (users at `@demo.tokengate`, fixed profile/service/lab
names, `sk-demo-` credential keys) and wiped on the next run — operator data is
never touched. `audit_logs` is append-only, so its demo entries are seeded once
and preserved. Re-running produces identical row counts. The script prints the
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
    api_key="tg-…",   # TokenGate API key (member or service)
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
| `MAX_CONNECTIONS` | `2048` | Listener connection ceiling (ThousandIsland) |
| `SESSION_MAX_AGE_SECONDS` | `604800` | Idle session lifetime (7 days, sliding) |
| `SESSION_ABSOLUTE_MAX_AGE_SECONDS` | `2592000` | Absolute session lifetime from login (30 days, not renewed) |
| `SESSION_COOKIE_SECURE` | auto | Force/clear the cookie `Secure` flag; unset = Plug default (secure only on HTTPS) |
| `TRUST_PROXY_HEADERS` | off | Take the client IP from the last `X-Forwarded-For` hop — only with a rewriting proxy in front |
| `PROXY_RECEIVE_TIMEOUT_MS` | `120000` | Upstream read timeout (per-provider override) |
| `FIRST_TOKEN_TIMEOUT_MS` | `30000` | Streaming: max wait for first chunk |
| `STREAM_IDLE_TIMEOUT_MS` | `60000` | Max gap between SSE chunks before the stream is cut |
| `CIRCUIT_BREAKER_THRESHOLD` | `3` | Failures before a breaker opens |
| `CIRCUIT_BREAKER_COOLDOWN_MS` | `30000` | Breaker open duration |
| `CIRCUIT_BREAKER_RATE_LIMIT_COOLDOWN_MS` | `20000` | Breaker cooldown after a 429 |
| `ROUTING_SLOW_THRESHOLD_MS` | `30000` | Latency that marks a credential degraded |
| `ROUTING_SLOW_PENALTY_MS` | `120000` | How long a slow credential sinks below healthy ones |
| `ECTO_SSL` / `ECTO_SSL_VERIFY` | on / off | DB SSL and cert verification |
| `ECTO_IPV6` | off | Connect to the DB over IPv6 |
| `PHX_SCHEME` / `PHX_PORT` | `https` / `443` | URL generation (set `http` behind a VPN proxy) |
| `CHECK_ORIGINS` | unset | Comma-separated allowed origins for CSRF/WS checks |
| `TOKENGATE_ADMIN_PASSWORD` | unset | Set it to bootstrap the admin at boot; unset = first admin created from `/onboarding` |
| `TOKENGATE_ADMIN_EMAIL` | `admin@tokengate.local` | Email of the bootstrapped admin (only used with the password) |
| `TELEGRAM_BOT_TOKEN` | unset | Telegram bot token (else read encrypted from the UI) |
| `PHX_SERVER` | set by the image | Runs the endpoint outside prod (the Dockerfile sets it) |
| `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | unset | Enable Google sign-in |
| `GOOGLE_OAUTH_ALLOWED_DOMAINS` | unset | Domains allowed to auto-register |
| `GOOGLE_OAUTH_REDIRECT_URI` | derived | Override the OAuth callback URL |
| `DNS_CLUSTER_QUERY` | unset | Node clustering DNS query |

`.env.example` is the **complete template** — core, session, proxy and this app's own
variables, each with its comment and a safe default:
`cp .env.example .env && $EDITOR .env`.

## The UI standard

The UI follows the family's **Commons** — theme and tokens, layout and responsive,
elements and **buttons by context**, cards, tables, modals, search pickers, charts,
states, shell — copied **byte-exact** from the `boilerplate` repo's `DESIGN.md`,
plus the section this app owns at the end of that same file: `## Custom — TokenGate`.

The Commons is edited **in the boilerplate repo and only there**, and propagates by
copying; an app never edits it in place. To see whether this app is still carrying
it byte-exact:

```bash
bash path/to/boilerplate/skeleton/check-commons.sh .   # exit 0 = Commons intact
```

## Production (Docker)

Multi-stage **Dockerfile** included: prebuilt hexpm Elixir image → slim Debian runtime,
non-root `app` user, port `4000`. The entrypoint runs **`Tokengate.Release.setup/0`**
(create the database → migrate → seed the admin) before boot, so the app never serves
against an un-migrated schema and a failed migration aborts the boot — the deploy rolls
back instead of shipping broken code. `SKIP_MIGRATIONS=1` bypasses it.

**Ports:** `PORT` (container, default `4000`) **must equal the platform's _Ports Exposes_**
— that is the real listen port. `PHX_PORT` / `PHX_SCHEME` only feed the generated URLs
(the external ones: `443` / `https`, or `4000` / `http` behind a VPN). The image sets no
`EXPOSE`: it would not change the listen.

**HTTPS:** `force_ssl` is compile-time and the image ships **HTTPS on**, like the rest
of the family. Deployed over plain HTTP behind a VPN, the build passes
`--build-arg DISABLE_FORCE_SSL=1` (in the platform's **build** variables, not
the runtime ones) and the runtime sets `PHX_SCHEME=http`. The two always move together:
with `force_ssl` on and `PHX_SCHEME=http`, Plug.SSL redirects every request to HTTPS —
and the port in that redirect cannot be configured (`Plug.SSL` fixes it at 443 for HSTS)
— where nothing is listening. The healthcheck would not catch it: it hits `127.0.0.1`,
which `config/prod.exs` excludes from the redirect, so the container keeps reporting
healthy while users hang.

**Behind the platform's proxy** (Coolify/Traefik, the normal case) set
`TRUST_PROXY_HEADERS=true`: without it every client shares the proxy's IP, which turns
the per-IP login bucket into a single shared one and records the proxy as the audit
`ip`. With it and the app exposed directly, the client can forge its own IP — so it is
a deployment fact, not a default.

Boot runs `priv/repo/seeds_prod.exs`: it creates **only** the admin user, and only when
`TOKENGATE_ADMIN_PASSWORD` is set (`TOKENGATE_ADMIN_EMAIL` optional, defaults to
`admin@tokengate.local`). The demo datasets (`priv/repo/seeds.exs`,
`priv/repo/demo_seeds.exs`) are development-only and refuse to run inside a release.

### First run

A fresh instance has no users, and without one there is nothing to log in with: `/` (and
`/login`) redirect to **`/onboarding`**, where the first account you create becomes the
global admin. The page disables itself — both actions bounce to `/login` as soon as a
user exists, and `Accounts.create_first_admin/1` re-checks inside a transaction under an
advisory lock (`pg_advisory_xact_lock`), so it cannot be used to mint a second admin (a
double-click or two replicas racing the form can't either).

That leaves a window: whoever reaches the instance first can claim it. Close it by
deploying behind your network boundary, or by setting `TOKENGATE_ADMIN_PASSWORD` so the
boot creates the admin before the app is ever exposed. Without that variable the boot
creates **nothing** — never a fallback password from this repository.

```bash
docker build -t tokengate .
docker run -p 4000:4000 --env-file .env tokengate
```

> 🩺 **Healthcheck:** the image ships a `HEALTHCHECK` on **`GET /health`** — a bare `200`
> that touches no database, so it passes while the boot tasks warm the connection pool.
> Point the proxy's health check at `/health` expecting `200`, **not** at `/`: `/`
> redirects to `/login` (302) and a proxy configured for 200 reports a healthy container
> as down → 502 Bad Gateway. Note the window before the listener exists: the entrypoint
> runs migrations first, so a proxy that gives up sooner will 502 during a deploy.

> ⚠️ **Migrations on partitioned tables:** `CREATE INDEX` on `request_logs` cannot use
> `CONCURRENTLY` (Postgres limitation). On a large existing table, run migrations in a
> maintenance window.

### Repairing the metrics rollup

The period KPIs of **Resumen** (`/stats/overview`) and the **dashboard** answer from the
hourly rollup (`request_metrics_hourly`) for everything older than the fresh 3-hour tail,
which is read from `request_logs` crudo. `/stats` (En vivo) and `/budget/global` read
`request_logs` only — so if the two groups ever disagree, the rollup is the one that is
wrong. The `RollupWorker` only re-aggregates the last 3 hours, so a rollup written by a
buggy version stays wrong until it is rebuilt:

```bash
bin/rollup-backfill                                  # últimos 90 días (retención)
ROLLUP_BACKFILL_DAYS=7 bin/rollup-backfill           # últimos 7 días
ROLLUP_BACKFILL_FROM=2026-09-01 bin/rollup-backfill  # desde una fecha (YYYY-MM-DD = 00:00 UTC)
mix tokengate.rollup.backfill --days 7               # same job outside a release
```

In a container that is already running it is `docker exec <container> bin/rollup-backfill`;
as a one-off (no app boot) override the entrypoint:
`docker run --rm --entrypoint /app/bin/rollup-backfill <image>` with the app's DB env vars.

One transaction per UTC day, delete + re-aggregate from `request_logs`: idempotent, safe
to re-run, resumable if it is interrupted (it logs a line per day). It is deliberately
**not** part of the boot — `Tokengate.Release.setup/0` never touches the rollup.

## Tests and gates

```bash
mix precommit   # the gate that closes the loop
```

What it chains: `compile --warnings-as-errors` → `deps.unlock --unused` →
`deps.audit` → `hex.audit` → `format` → `gettext.extract --check-up-to-date` → `test`.
The two audits are both there on purpose: `deps.audit` answers against hex.pm and
`hex.audit` against osv.dev, and they disagree (see **Security › Supply chain**).

The `/health` probe carries its own test that runs **without** a sandbox owner
(`test/tokengate_web/controllers/health_controller_test.exs`): a `/health` that queried
the database would answer 503 there and turn the suite red. That is the regression the
container's `HEALTHCHECK` depends on not happening, so the test pins it structurally
rather than by convention.

Security regressions have their own locks, so a future refactor can't quietly reopen
them: `test/tokengate_web/session_revocation_test.exs` (suspension and password rotation
cut live sessions and API keys, plus the absolute lifetime cap),
`test/tokengate_web/plugs/proxy_pre_auth_test.exs` (no credential ⇒ 401 before the body
is parsed), `test/tokengate_web/plugs/login_rate_limit_test.exs` (the two buckets are
independent) and `test/tokengate_web/controllers/audit_export_controller_test.exs` (CSV
formula neutralization).

## Tech stack

Phoenix 1.8 + LiveView · Bandit · Ecto/Postgres (RANGE partitions) · Finch (upstream
HTTP/SSE) · Req (outbound) · Oban · Tailwind CSS v4 + daisyUI (dim) · esbuild ·
bcrypt_elixir

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 Álvaro Lizama.
The license covers the whole repository: the Phoenix server, the admin UI and
the Docker production image. Third-party dependencies keep their own licenses.
