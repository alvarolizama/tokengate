#!/usr/bin/env bash
#
# test-db-tune.sh — toggle cluster-level Postgres durability for fast test runs.
#
# The TokenGate suite is I/O-bound (55-75% CPU idle), so WAL durability is the
# biggest speed lever. This toggles it CLUSTER-WIDE (every database on the
# instance, including dev), so it is opt-in and reversible:
#
#   scripts/test-db-tune.sh fast    # fsync=off + synchronous_commit=off
#   scripts/test-db-tune.sh safe    # restore defaults (fsync=on, synchronous_commit=on)
#   scripts/test-db-tune.sh status  # show current values
#
# WARNING: `fast` reduces crash-safety for ALL databases on this instance. On a
# disposable dev/test Postgres that is fine; never leave it on a production box.
# Run `safe` when you are done measuring to restore durability.
set -euo pipefail

PGHOST="${PGHOST:-localhost}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"

psql_run() {
  PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 "$@"
}

case "${1:-status}" in
  fast)
    psql_run -q \
      -c "ALTER SYSTEM SET fsync = off" \
      -c "ALTER SYSTEM SET synchronous_commit = off" \
      -c "SELECT pg_reload_conf()" >/dev/null
    echo "fast: fsync=off synchronous_commit=off applied (cluster-wide)."
    echo "      revert with: $0 safe"
    ;;
  safe)
    psql_run -q \
      -c "ALTER SYSTEM RESET fsync" \
      -c "ALTER SYSTEM RESET synchronous_commit" \
      -c "SELECT pg_reload_conf()" >/dev/null
    echo "safe: fsync/synchronous_commit restored to server defaults."
    ;;
  status)
    psql_run -tAc "select name, setting from pg_settings where name in ('fsync','synchronous_commit') order by name"
    ;;
  *)
    echo "usage: $0 {fast|safe|status}" >&2
    exit 2
    ;;
esac