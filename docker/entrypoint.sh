#!/bin/sh
# TokenGate container entrypoint.
#
# Runs Tokengate.Release.setup/0 (create DB if missing → migrate → seed the
# admin user) before starting the Phoenix release. On a fresh database it
# creates the schema and the admin account. On subsequent deploys it
# short-circuits (DB already exists) and only runs pending migrations.
#
# The seed is priv/repo/seeds_prod.exs: the admin user and NOTHING ELSE, and
# only when TOKENGATE_ADMIN_PASSWORD is set. Without it the boot creates no
# user at all and `/` sends the owner to /onboarding, where the first account
# becomes the global admin — that is the default path for a fresh instance.
# The demo datasets under priv/repo (seeds.exs, demo_seeds.exs) are dev-only
# and abort if they ever run without Mix.
#
# Admin credentials come from TOKENGATE_ADMIN_EMAIL / TOKENGATE_ADMIN_PASSWORD
# (email defaults to admin@tokengate.local). The seed is idempotent and never
# duplicates the user.
#
# Set SKIP_MIGRATIONS=1 to bypass (one-off task containers).
set -e

if [ "$SKIP_MIGRATIONS" = "1" ]; then
  echo "[entrypoint] SKIP_MIGRATIONS=1, skipping setup."
else
  echo "[entrypoint] running setup (create DB → migrate → seed admin)..."
  bin/tokengate eval "Tokengate.Release.setup"
fi

echo "[entrypoint] starting tokengate release..."
exec bin/tokengate start
