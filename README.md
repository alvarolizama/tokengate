<img src="docs/screenshots/dashboard.png" alt="TokenGate — LLM API gateway" width="100%">

# TokenGate

An OpenAI-compatible **LLM API gateway** built with **Phoenix 1.8 + LiveView**. It sits between your agents/apps and the model providers (OpenAI, OpenRouter, Fireworks, oMLX, …): your clients call TokenGate with their TokenGate API key, and TokenGate routes each request to the best provider credential — with budgets, rate limits, circuit breakers, and full cost accounting in between.

Think "LiteLLM, but as an Elixir app with a real admin UI".

## Key features

- **OpenAI-compatible proxy API** — `POST /v1/chat/completions` (streaming SSE + non-streaming), `POST /v1/embeddings`, `POST /v1/rerank`, `GET /v1/models`. Clients keep using the OpenAI SDK; they just change the base URL and the key.
- **Model aliases** — clients ask for `gpt-4o`, TokenGate maps that alias to one or more concrete providers. Switching backends is an admin operation, not a client deploy.
- **Priority routing + sticky sessions** — providers are ordered by priority; the same API key sticks to the same provider to preserve prompt caches. Exclusive providers can be scoped to one member or one team.
- **Fallback matrix** — auth errors (401/402/403) disable the credential and fall back; timeouts fall back immediately; fast errors (5xx/429) retry the same provider up to 3 times before moving on. Circuit breaker per credential with configurable threshold/cooldown.
- **Two-gate throttling** — per-user limits (team defaults + member overrides: RPM, concurrency) protect TokenGate; per-credential limits (`max_rpm`, `max_concurrent`, `max_concurrent_per_user`) protect the upstream API key.
- **Monthly budgets in USD** — per member (team default + member extra) and per service. ETS hot counters (micro-USD) checked pre-flight; Postgres `request_logs` is the durable truth with debounced drift-correction.
- **Cost tracking** — provider-reported cost (`usage.cost`) is recorded per request; responses gain `X-Tokengate-Cost` header. Included/subscription providers (`billing_mode: included`) count as $0.
- **Real-time admin dashboard** — live metrics (requests, errors, tokens, cost, latency histogram), Monitor page with per-model bars + 60-minute sparklines, live Logs view with in-flight requests, CSV export.
- **Services** — machine-to-machine consumers (not tied to a user) with their own API key, budgets, limits, and model grants. Supervisors get read-only visibility.
- **Observability webhooks** — per-destination HMAC-signed (`sha256=…`) delivery of every request log; OTLP export as well.
- **Audit log** — admin actions (impersonation, credential changes, team/user management) are persisted.

## Quick start

```bash
git clone git@github.com:alvarolizama/tokengate.git && cd tokengate
mix setup        # deps → DB → migrations → assets → seed
mix phx.server
```

Visit [localhost:4000](http://localhost:4000) and sign in with the seeded admin (see `priv/repo/seeds.exs`; email defaults to `admin@tokengate.local`, overridable via `TOKENGATE_ADMIN_EMAIL`). Then create a provider + credential, a model alias, grant it to a team, and issue an API key — you can proxy a request in ~5 minutes.

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
    messages=[{"role": "user", "content": "Qué pasó"}],
)
```

Optional agent-identification headers (OpenRouter-style): `X-Agent-Type` (enforced dimension for metrics/limits), `X-Title`, `HTTP-Referer`, `User-Agent`.

## Architecture

```
client ──► ApiAuth (bearer → TeamMember/Service)
        ──► Limits (ETS sliding-window RPM + concurrency)
        ──► Router (alias → model_provider → credential; ETS-cached, 60s TTL)
        ──► Budgets (ETS micro-USD counters, pre-flight check)
        ──► OpenAIAdapter (Finch; streaming via stream_while)
        ──► response + cost accounting (Collector ETS, Oban WriteWorker → Postgres)
```

Hot path discipline: auth, limits, budgets and routing read from **ETS only**. Postgres is touched asynchronously via Oban (`Logs.WriteWorker` for request logs, `Budgets.SyncWorker` for drift correction). `Routing.Cache` memoizes provider lists per (alias, team) for 60s and invalidates on admin writes.

State lives in:

- **Postgres** — teams, users, services, API keys (sha256-hashed), providers, credentials, model aliases/providers, partitioned `request_logs` (daily RANGE partitions), audit logs, Oban jobs.
- **ETS** — limits (RPM buckets + in-flight), budgets (micro-USD), metrics (counters + latency histogram), routing cache, in-flight registry, metrics window (sparklines), circuit breakers, sticky routes.

## Authentication

- **Dashboard:** email/password (Bcrypt, uniform error messages against enumeration) and optional **Google OAuth** (enabled when `GOOGLE_OAUTH_CLIENT_ID`/`SECRET` are set; auto-registration restricted by `GOOGLE_OAUTH_ALLOWED_DOMAINS`). Sessions are encrypted cookies with sliding expiration (default 4h idle).
- **Proxy API:** `Authorization: Bearer tg-…` — only the sha256 of the token is stored. One active key per team member / per service; rotation replaces material in place.
- **Impersonation:** admins can view the app as any user (except the root admin); every start/stop is audited.

## Environment variables

Required in prod: `SECRET_KEY_BASE`, `DATABASE_URL`, `PHX_HOST`, `WEBHOOK_SECRET`, `SESSION_SIGNING_SALT`, `SESSION_ENCRYPTION_SALT`.

Common optional knobs:

| Var | Default | What it tunes |
| --- | --- | --- |
| `PORT` | `4000` | HTTP port |
| `POOL_SIZE` | `10` | DB connection pool |
| `SESSION_MAX_AGE_SECONDS` | `14400` | Idle session lifetime (sliding) |
| `PROXY_RECEIVE_TIMEOUT_MS` | `60000` | Upstream read timeout default |
| `FIRST_TOKEN_TIMEOUT_MS` | `30000` | Streaming: max wait for first chunk before fallback |
| `CIRCUIT_BREAKER_THRESHOLD` | `3` | Failures before a credential's breaker opens |
| `CIRCUIT_BREAKER_COOLDOWN_MS` | `30000` | Breaker open duration |
| `ROUTING_SLOW_THRESHOLD_MS` | `30000` | Latency that marks a credential "degraded" |
| `ECTO_SSL` / `ECTO_SSL_VERIFY` | on / off | DB SSL and certificate verification |
| `CHECK_ORIGINS` | unset | Extra allowed origins (multi-scheme deploys) |
| `GOOGLE_OAUTH_*` | unset | Google sign-in (see Authentication) |

Build-time: `DISABLE_FORCE_SSL=1` (Dockerfile ARG) for plain-HTTP deploys — `force_ssl` is compile-time in Phoenix.

## Production

Ships with a multi-stage **Dockerfile** (prebuilt hexpm Elixir image → slim Debian runtime, non-root `app` user). The entrypoint applies migrations before boot; `SKIP_MIGRATIONS=1` bypasses.

```bash
docker build -t tokengate .
docker run -p 4001:4001 --env-file .env tokengate
```

Oban runs a monthly cron (`0 0 1 * *`, `Budgets.ResetWorker`) that resets monthly ETS budget counters on the 1st. Queues: `logs` (20), `webhooks` (10), `budgets` (5), `default` (10).

> ⚠️ **Migrations on partitioned tables:** `CREATE INDEX` on `request_logs` cannot use `CONCURRENTLY` (Postgres limitation). On a large existing table, run migrations in a maintenance window.

## Tech stack

- Phoenix 1.8 + LiveView, Bandit, Ecto/Postgres (RANGE-partitioned request logs)
- Finch for upstream HTTP (SSE streaming via `stream_while`), Req for outbound calls (OAuth)
- Oban for async writes, drift correction, webhooks, monthly budget reset
- Tailwind CSS v4 (no daisyUI), esbuild
- bcrypt_elixir, telemetry, dns_cluster, tzdata

## Pre-commit

```bash
mix precommit   # compile --warnings-as-errors → deps.unlock --unused → deps.audit → format → test
```

`deps.audit` (mix_audit) currently flags transitive `hackney < 4.0.1` (via swoosh/tzdata, low/moderate severity) — upgrade path is a swoosh release compatible with hackney 4.x.

## License

MIT
