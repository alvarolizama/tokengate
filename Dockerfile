# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage — prebuilt Elixir/OTP image (no mise, no kerl, no source builds)
# ---------------------------------------------------------------------------
# TokenGate targets Elixir ~> 1.15 (mix.exs) but is developed on 1.20.x / OTP
# 29. Pin the closest published hexpm/elixir image to the local toolchain so
# the container matches what devs actually run. Verify the tag at
# https://hub.docker.com/r/hexpm/elixir/tags and keep the runtime image's
# bookworm date (below) matching to avoid glibc drift.
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.2-erlang-29.0.3-debian-bookworm-20260713-slim
ARG DEBIAN_RUNTIME=debian:bookworm-20260713-slim

FROM ${ELIXIR_IMAGE} AS build

# Build deps: git for git-sourced hex deps (heroicons), build-essential for
# any NIFs (bcrypt_elixir). No node needed — the tailwind/esbuild hex
# wrappers fetch their own platform binaries.
RUN apt-get update -y \
  && apt-get install -y build-essential git curl ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# force_ssl is compile-time (see config/prod.exs). For plain-HTTP deploys
# (VPN tunnel, no TLS terminator) build with:
#   docker build --build-arg DISABLE_FORCE_SSL=1 .
# and set PHX_SCHEME=http at runtime.
ARG DISABLE_FORCE_SSL=""
ENV DISABLE_FORCE_SSL=${DISABLE_FORCE_SSL}

# --- Dependencies (cached until mix.exs/mix.lock change) -------------------
# Copy only the manifest + config so dep fetch/compile is layer-cached across
# app code changes. `mix deps.get` MUST run before `mix compile` — otherwise
# a stale mix.lock (heroicons ref drifted from mix.exs options) aborts the
# build with "lock outdated".
COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod

# Compile Erlang/rebar3 deps first with a memory-constrained Erlang VM.
# Coolify build containers often have tight memory limits (512 MB-1 GB);
# the default Erlang VM (one scheduler per CPU core) can OOM during
# parallel rebar3 compilation. +S 1:1 limits to 1 scheduler.
RUN ERL_AFLAGS="+S 1:1" mix deps.compile idna telemetry telemetry_poller
RUN mix deps.compile

# --- Application + assets --------------------------------------------------
COPY lib lib
COPY priv priv
COPY assets assets
COPY rel rel

RUN mix compile
RUN mix assets.deploy

# --- Release ---------------------------------------------------------------
# Produces _build/prod/rel/tokengate/ with bin/tokengate, bin/migrate,
# bin/server, bin/setup (the last three come from rel/overlays).
# `mix release` without a name uses the app name (:tokengate) from mix.exs.
RUN mix release

# ---------------------------------------------------------------------------
# Runtime stage — slim Debian with only what the release needs
# ---------------------------------------------------------------------------
FROM ${DEBIAN_RUNTIME} AS app

# curl is needed for Coolify's container health check (slim image omits it).
RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# UTF-8 locale — Elixir expects it at runtime.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Run as non-root.
RUN useradd --create-home app
COPY --from=build --chown=app:app /app/_build/prod/rel/tokengate ./

# Entrypoint applies pending migrations (and seeds the admin user on first
# boot) before starting the release, so the app never serves against an
# un-migrated schema. A failed migration aborts boot (Coolify rolls back)
# instead of shipping broken code. Set SKIP_MIGRATIONS=1 to bypass.
COPY --chown=app:app docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

USER app

ENV HOME=/app MIX_ENV=prod PHX_SERVER=true PORT=4001

EXPOSE 4001

ENTRYPOINT ["/app/entrypoint.sh"]
