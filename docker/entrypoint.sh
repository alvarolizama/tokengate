#!/bin/sh
# TokenGate container entrypoint.
#
# Runs Tokengate.Release.setup/0 (create DB if missing → migrate → seed the
# admin user) before starting the Phoenix release. On a fresh database it
# creates the schema and the admin account. On subsequent deploys it
# short-circuits (DB already exists) and only runs pending migrations.
#
# Admin credentials come from TOKENGATE_ADMIN_EMAIL / TOKENGATE_ADMIN_PASSWORD
# (defaults: admin@tokengate.local / tokengate-admin-secret-1 — override in
# prod!). The seed is idempotent and never duplicates the user.
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
