#!/usr/bin/env bash
#
# test-parallel.sh — run the TokenGate test suite across N OS-process partitions.
#
# Each partition is a full BEAM VM with its own ETS/PubSub/app tree and its own
# database (tokengate_test<i>, via MIX_TEST_PARTITION), so the 421s of
# `async: false` tests that serialize inside a single VM run concurrently
# across partitions without sharing any state.
#
# Usage:
#   scripts/test-parallel.sh                     # 6 partitions, weighted split, pool 12
#   scripts/test-parallel.sh -n 4 -p 18 -m 14    # explicit partitions / pool / max-cases
#   scripts/test-parallel.sh --mode partitions   # literal `mix test --partitions N`
#   scripts/test-parallel.sh --balance files     # file round-robin, no weights
#   scripts/test-parallel.sh --print-plan        # show the (deterministic) split
#   scripts/test-parallel.sh --fresh             # create+migrate instead of cloning
#
# Connection budget: N * TEST_POOL_SIZE must stay under Postgres
# max_connections minus headroom. The script checks it when psql is reachable
# and refuses to start an over-budget run (override with --force).
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PARTITIONS="${PARTITIONS:-6}"
POOL="${TEST_POOL_SIZE:-}"
MAX_CASES="${TEST_MAX_CASES:-}"
SEED="${SEED:-0}"
MODE="${MODE:-files}"
BALANCE="${BALANCE:-tests}"
CONN_HEADROOM="${CONN_HEADROOM:-25}"   # connections left for psql/migrations/other
POOL_HEADROOM="${POOL_HEADROOM:-4}"    # pool slots left for Oban/boot tasks
SKIP_SETUP="${SKIP_SETUP:-0}"
RETRY_FAILED="${RETRY_FAILED:-1}"
EXPECTED_TESTS="${EXPECTED_TESTS:-}"
LOG_DIR="${LOG_DIR:-tmp/test-parallel}"
DROP=0
FRESH=0
FORCE=0
PRINT_PLAN=0
COMPILE=1
EXTRA=()

usage() {
  sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--partitions) PARTITIONS="$2"; shift 2 ;;
    -p|--pool)       POOL="$2"; shift 2 ;;
    -m|--max-cases)  MAX_CASES="$2"; shift 2 ;;
    -s|--seed)       SEED="$2"; shift 2 ;;
    --mode)          MODE="$2"; shift 2 ;;
    --balance)       BALANCE="$2"; shift 2 ;;  # tests (greedy LPT) | files (round-robin)
    --no-setup)      SKIP_SETUP=1; shift ;;
    --no-retry)      RETRY_FAILED=0; shift ;;
    --retry)         RETRY_FAILED="$2"; shift 2 ;;
    --drop)          DROP=1; shift ;;
    --fresh)         FRESH=1; shift ;;   # create+migrate instead of cloning a template DB
    --template)      TEMPLATE="$2"; shift 2 ;;
    --no-compile)    COMPILE=0; shift ;;
    --print-plan)    PRINT_PLAN=1; shift ;;
    --force)         FORCE=1; shift ;;
    -h|--help)       usage ;;
    --)              shift; EXTRA+=("$@"); break ;;
    *)               EXTRA+=("$1"); shift ;;
  esac
done

case "$MODE" in partitions|files) ;; *) echo "unknown --mode: $MODE (use partitions|files)" >&2; exit 2 ;; esac
case "$PARTITIONS" in ''|*[!0-9]*) echo "--partitions must be a positive integer" >&2; exit 2 ;; esac
[ "$PARTITIONS" -ge 1 ] || { echo "--partitions must be >= 1" >&2; exit 2; }

# ---------------------------------------------------------------- connection math
PGHOST_="${PGHOST:-localhost}"
PGUSER_="${PGUSER:-postgres}"
PGPASSWORD_="${PGPASSWORD:-postgres}"
MAX_CONN=""
if command -v psql >/dev/null 2>&1; then
  MAX_CONN="$(PGPASSWORD="$PGPASSWORD_" psql -h "$PGHOST_" -U "$PGUSER_" -d postgres \
                -tAc 'show max_connections' 2>/dev/null | tr -d '[:space:]')"
  case "$MAX_CONN" in ''|*[!0-9]*) MAX_CONN="" ;; esac
fi

if [ -z "$POOL" ]; then
  if [ -n "$MAX_CONN" ]; then
    POOL=$(( (MAX_CONN - CONN_HEADROOM) / PARTITIONS ))
  else
    POOL=18
  fi
  [ "$POOL" -gt 36 ] && POOL=36   # never exceed the single-run default
fi
[ "$POOL" -ge 2 ] || { echo "derived pool size too small ($POOL); lower --partitions" >&2; exit 2; }

if [ -z "$MAX_CASES" ]; then
  MAX_CASES=$(( POOL - POOL_HEADROOM ))
  [ "$MAX_CASES" -lt 2 ] && MAX_CASES=2
fi

TOTAL_CONNS=$(( PARTITIONS * POOL ))
if [ -n "$MAX_CONN" ]; then
  BUDGET=$(( MAX_CONN - CONN_HEADROOM ))
  if [ "$TOTAL_CONNS" -gt "$BUDGET" ] && [ "$FORCE" -eq 0 ]; then
    echo "REFUSING TO RUN: $PARTITIONS partitions x pool $POOL = $TOTAL_CONNS connections," >&2
    echo "but only $BUDGET are safe (max_connections=$MAX_CONN, headroom=$CONN_HEADROOM)." >&2
    echo "Lower --partitions or --pool, or pass --force." >&2
    exit 2
  fi
fi

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------- partition plan
# plan.tsv: "<partition>\t<file>\t<weight>".
#   balance=files -> sorted files, round-robin by index: byte-for-byte what
#                    Mix.Tasks.Test.filter_by_partition/3 does with --partitions.
#   balance=tests -> greedy longest-processing-time over each file's test count
#                    (sort by weight desc then path, always drop into the
#                    least-loaded bin). Files held as whole units, so no file is
#                    ever split across DBs; ties break on path and bin index,
#                    so the assignment is fully reproducible.
PLAN_FILE="$LOG_DIR/plan.tsv"
BUILD_PLAN_WAS=""

build_plan() {
  local files
  [ "$BUILD_PLAN_WAS" = "$MODE/$BALANCE/$PARTITIONS" ] && return 0
  files="$(find test -name '*_test.exs' | sort)"
  if [ "$MODE" = "files" ] && [ "$BALANCE" = "tests" ]; then
    printf '%s\n' "$files" | awk -v n="$PARTITIONS" '
      { f[NR-1] = $0; c = NR }
      END {
        for (i = 0; i < c; i++) {
          w = 0
          while ((getline line < f[i]) > 0) if (line ~ /^[ \t]*test[ \t(]/) w++
          close(f[i])
          weight[i] = w
        }
        for (i = 0; i < c; i++) idx[i] = i
        for (i = 1; i < c; i++) {
          v = idx[i]; j = i - 1
          while (j >= 0 && (weight[idx[j]] < weight[v] || (weight[idx[j]] == weight[v] && f[idx[j]] > f[v]))) {
            idx[j+1] = idx[j]; j--
          }
          idx[j+1] = v
        }
        for (k = 0; k < n; k++) load[k] = 0
        for (i = 0; i < c; i++) {
          k = idx[i]; best = 0
          for (b = 1; b < n; b++) if (load[b] < load[best]) best = b
          load[best] += weight[k]
          printf "%d\t%s\t%d\n", best + 1, f[k], weight[k]
        }
      }' > "$PLAN_FILE"
  else
    printf '%s\n' "$files" | awk -v n="$PARTITIONS" '{ printf "%d\t%s\t1\n", (NR-1)%n+1, $0 }' > "$PLAN_FILE"
  fi
  BUILD_PLAN_WAS="$MODE/$BALANCE/$PARTITIONS"
}

plan_for() { awk -F'\t' -v p="$1" '$1 == p { print $2 }' "$PLAN_FILE"; }
plan_weight() { awk -F'\t' -v p="$1" '$1 == p { s += $3 } END { print s + 0 }' "$PLAN_FILE"; }

build_plan

if [ "$PRINT_PLAN" -eq 1 ]; then
  echo "# mode=$MODE balance=$BALANCE partitions=$PARTITIONS seed=$SEED pool=$POOL max_cases=$MAX_CASES"
  for ((i=1; i<=PARTITIONS; i++)); do
    echo "## partition $i ($(plan_weight "$i") tests)"
    plan_for "$i"
  done
  exit 0
fi

echo "== test-parallel =="
echo "   partitions : $PARTITIONS"
echo "   pool/partition: $POOL  (total $TOTAL_CONNS connections${MAX_CONN:+, max_connections=$MAX_CONN})"
echo "   max_cases  : $MAX_CASES"
echo "   seed       : $SEED"
echo "   mode       : $MODE (balance=$BALANCE)"
echo "   logs       : $LOG_DIR"
echo

export MIX_ENV=test

# ---------------------------------------------------------------- precompile
# One serial compile so the N partition VMs can run with --no-compile:
# concurrent `mix compile` in the same _build races on manifests.
if [ "$COMPILE" -eq 1 ]; then
  echo "-- precompiling (serial) ..."
  if ! mix compile > "$LOG_DIR/compile.log" 2>&1; then
    echo "compile failed, see $LOG_DIR/compile.log" >&2
    tail -20 "$LOG_DIR/compile.log" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- setup
# Preferred path: clone `tokengate_test` (the DB a plain `mix test` uses) into
# every partition DB. A fresh create+migrate database is NOT equivalent: the
# boot-time catalog seed is lossy on a virgin schema (18 of 237 snapshot rows
# hit a unique conflict and are dropped), and providers/catalog_test.exs
# asserts the seasoned 237-row mirror. Cloning keeps partitions byte-identical
# to the DB the baseline runs against — and skips 167 migrations per partition.
TEMPLATE="${TEMPLATE:-tokengate_test}"
USE_TEMPLATE=0
if [ "$FRESH" -eq 0 ] && [ -n "$TEMPLATE" ]; then
  have_template="$(PGPASSWORD="$PGPASSWORD_" psql -h "$PGHOST_" -U "$PGUSER_" -d postgres \
                    -tAc "select 1 from pg_database where datname = '$TEMPLATE'" 2>/dev/null | tr -d '[:space:]')"
  [ "$have_template" = "1" ] && USE_TEMPLATE=1
elif [ "$FRESH" -eq 1 ]; then
  USE_TEMPLATE=0
fi

echo "   database   : $([ "$USE_TEMPLATE" -eq 1 ] && echo "clone of $TEMPLATE" || echo "fresh create+migrate")"

if [ "$USE_TEMPLATE" -eq 0 ] && [ "$FRESH" -eq 0 ] && [ -n "$TEMPLATE" ]; then
  echo "-- template DB '$TEMPLATE' not found; falling back to create+migrate"
  echo "   (fresh DBs fail 3 catalog tests for a pre-existing seed bug; see notes)"
fi

if [ "$SKIP_SETUP" -eq 0 ]; then
  if [ "$USE_TEMPLATE" -eq 1 ]; then
    echo "-- cloning '$TEMPLATE' into $PARTITIONS partition databases (parallel) ..."
  else
    echo "-- creating/migrating $PARTITIONS partition databases (parallel) ..."
  fi

  setup_pids=(); setup_idx=()
  for ((i=1; i<=PARTITIONS; i++)); do
    log="$LOG_DIR/setup-$i.log"
    (
      if [ "$USE_TEMPLATE" -eq 1 ]; then
        PGPASSWORD="$PGPASSWORD_" psql -h "$PGHOST_" -U "$PGUSER_" -d postgres -q -v ON_ERROR_STOP=1 \
          -c "DROP DATABASE IF EXISTS \"tokengate_test$i\" WITH (FORCE)" \
          -c "CREATE DATABASE \"tokengate_test$i\" TEMPLATE \"$TEMPLATE\""
      else
        if [ "$DROP" -eq 1 ]; then mix ecto.drop --quiet; fi
        mix ecto.create --quiet && mix ecto.migrate --quiet
      fi
    ) > "$log" 2>&1 &
    setup_pids+=("$!")
    setup_idx+=("$i")
  done
  setup_fail=0
  for ((j=0; j<PARTITIONS; j++)); do
    if ! wait "${setup_pids[$j]}"; then
      echo "   partition ${setup_idx[$j]} setup FAILED ($LOG_DIR/setup-${setup_idx[$j]}.log)" >&2
      tail -5 "$LOG_DIR/setup-${setup_idx[$j]}.log" >&2
      setup_fail=1
    fi
  done
  if [ "$setup_fail" -ne 0 ]; then
    echo "setup failed; aborting" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- run
echo "-- running tests ..."
pids=(); starts=(); ends=(); codes=()
run_start=$(date +%s)

for ((i=1; i<=PARTITIONS; i++)); do
  log="$LOG_DIR/partition-$i.log"
  starts[$i]=$(date +%s)
  if [ "$MODE" = "files" ]; then
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(plan_for "$i")
    (
      MIX_TEST_PARTITION="$i" MIX_TEST_PARTITION_COUNT="$PARTITIONS" TEST_POOL_SIZE="$POOL" TEST_MAX_CASES="$MAX_CASES" \
        mix test --seed "$SEED" --max-cases "$MAX_CASES" --no-compile \
        ${EXTRA[@]+"${EXTRA[@]}"} "${files[@]}" > "$log" 2>&1
    ) &
  else
    (
      MIX_TEST_PARTITION="$i" MIX_TEST_PARTITION_COUNT="$PARTITIONS" TEST_POOL_SIZE="$POOL" TEST_MAX_CASES="$MAX_CASES" \
        mix test --partitions "$PARTITIONS" --seed "$SEED" --max-cases "$MAX_CASES" \
        --no-compile ${EXTRA[@]+"${EXTRA[@]}"} > "$log" 2>&1
    ) &
  fi
  pids[$i]=$!
  echo "   partition $i started (pid ${pids[$i]})"
done

trap 'echo; echo "interrupted; killing partitions"; for ((k=1;k<=PARTITIONS;k++)); do kill "${pids[$k]:-}" 2>/dev/null; done; exit 130' INT TERM

# Wait for each partition as it actually finishes (not in id order) so the
# per-partition wall times are real: poll with kill -0, bash reaps exited
# children, so the pid disappears from the process table once done.
rc=0
remaining=$PARTITIONS
deadline=$(( $(date +%s) + ${MAX_WALL:-3600} ))
while [ "$remaining" -gt 0 ]; do
  for ((i=1; i<=PARTITIONS; i++)); do
    [ "${alive[$i]:-1}" = "0" ] && continue
    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
      wait "${pids[$i]}"
      code=$?
      ends[$i]=$(date +%s)
      codes[$i]=$code
      alive[$i]=0
      remaining=$(( remaining - 1 ))
      [ "$code" -ne 0 ] && rc=1
      printf '   partition %s done in %ss (exit %s)\n' "$i" "$(( ends[i] - starts[i] ))" "$code"
    fi
  done
  if [ "$remaining" -gt 0 ]; then
    if [ "$(date +%s)" -gt "$deadline" ]; then
      echo "MAX_WALL exceeded; killing remaining partitions" >&2
      for ((i=1; i<=PARTITIONS; i++)); do
        [ "${alive[$i]:-1}" = "1" ] && kill "${pids[$i]}" 2>/dev/null
      done
      rc=1
      break
    fi
    sleep 1
  fi
done

run_wall=$(( $(date +%s) - run_start ))

# ---------------------------------------------------------------- retry (flaky only)
# A handful of tests assert wall-clock timing or a LiveView render inside a
# 100ms window; under 4 concurrent VMs they can miss it. Retry ONLY the files
# that failed, in the same partition DB and with the same seed, and report the
# retry in the summary — never silently.
retried_note=""
if [ "$rc" -ne 0 ] && [ "$RETRY_FAILED" -gt 0 ]; then
  declare -a retried
  for ((i=1; i<=PARTITIONS; i++)); do
    [ "${codes[$i]}" -eq 0 ] && continue
    # ExUnit prints the failing location on its own line ("     test/x_test.exs:12");
    # anchoring at EOL keeps stacktrace frames ("...:12: (test)") out of the list.
    files="$(grep -oE '^[[:space:]]+test/[A-Za-z0-9_./-]+_test\.exs:[0-9]+$' "$LOG_DIR/partition-$i.log" 2>/dev/null | tr -d ' ' | cut -d: -f1 | sort -u)"
    [ -z "$files" ] && continue
    echo "-- partition $i failed; retrying its failing file(s):"
    echo "$files" | sed 's/^/     /'
    rlog="$LOG_DIR/partition-$i-retry.log"
    ( cd "$ROOT" && MIX_TEST_PARTITION="$i" MIX_TEST_PARTITION_COUNT="$PARTITIONS" \
        TEST_POOL_SIZE="$POOL" TEST_MAX_CASES="$MAX_CASES" \
        mix test --seed "$SEED" --max-cases "$MAX_CASES" --no-compile $files > "$rlog" 2>&1 )
    if [ $? -eq 0 ]; then
      codes[$i]=0
      retried[$i]=1
      retried_note="$retried_note p$i:$(echo "$files" | tr '\n' ',' | sed 's/,$//')"
    else
      echo "   partition $i retry FAILED too (see $rlog)" >&2
    fi
  done
  rc=0
  for ((i=1; i<=PARTITIONS; i++)); do [ "${codes[$i]}" -ne 0 ] && rc=1; done
fi

# ---------------------------------------------------------------- aggregate
# Elixir >= 1.20 prints:  "Result: 2389 passed (25 doctests, 2364 tests)"
#                        "Result: 3 failed, 2386 passed (2389 tests)"
# Older versions print:   "2389 tests, 0 failures" / "25 doctests, 2364 tests, 0 failures"
# parse_log -> "total failures" (0 0 when no summary line at all).
count_of() { # $1 = line, $2 = word (passed|failed|skipped|invalid)
  printf '%s' "$1" | grep -oE "[0-9]+ $2" | head -1 | grep -oE '^[0-9]+'
}

parse_log() {
  local log="$1" line inner tests doctests passed failed invalid total failures
  line="$(grep -E '^Result: ' "$log" | tail -1)"

  if [ -n "$line" ]; then
    # Newer ExUnit prints "Result: 392/393 passed" plus a separate
    # "Failed: 1 test" line; the older "N passed (M tests)" form has no
    # fraction. Handle the fraction first so failures are never undercounted.
    local frac failed_line
    frac="$(printf '%s' "$line" | grep -oE '[0-9]+/[0-9]+ passed' | head -1)"
    if [ -n "$frac" ]; then
      total="${frac#*/}"; total="${total%% *}"
      failures=0
      failed_line="$(grep -E '^Failed: [0-9]+ test' "$log" | tail -1)"
      [ -n "$failed_line" ] && failures="$(printf '%s' "$failed_line" | grep -oE '[0-9]+' | head -1)"
      echo "$total $failures"
      return
    fi
    passed=$(count_of "$line" passed); passed=${passed:-0}
    failed=$(count_of "$line" failed); failed=${failed:-0}
    invalid=$(count_of "$line" invalid); invalid=${invalid:-0}
    inner="$(printf '%s' "$line" | sed -nE 's/.*\(([^)]*)\).*/\1/p')"
    tests=""; doctests=""
    [ -n "$inner" ] && tests=$(count_of "$inner" tests)
    [ -n "$inner" ] && doctests=$(count_of "$inner" doctests)
    total=$(( ${tests:-0} + ${doctests:-0} ))
    [ "$total" -eq 0 ] && total=$(( passed + failed + invalid ))
    failures=$(( failed + invalid ))
    echo "$total $failures"
    return
  fi

  line="$(grep -E '^([0-9]+ doctests, )?[0-9]+ tests, [0-9]+ failures?' "$log" | tail -1)"
  if [ -z "$line" ]; then echo "0 0"; return; fi
  tests="$(printf '%s' "$line" | sed -E 's/^([0-9]+ doctests, )?([0-9]+) tests.*/\2/')"
  failures="$(printf '%s' "$line" | sed -E 's/.* ([0-9]+) failures?.*/\1/')"
  doctests="$(printf '%s' "$line" | sed -nE 's/^([0-9]+) doctests,.*/\1/p')"
  echo "$(( ${tests:-0} + ${doctests:-0} )) ${failures:-0}"
}

total=0; total_fail=0; missing=0
echo
printf '%-10s %8s %9s %8s %7s  %-22s %s\n' "partition" "wall(s)" "tests" "failures" "exit" "note" "log"
for ((i=1; i<=PARTITIONS; i++)); do
  log="$LOG_DIR/partition-$i.log"
  read -r n f <<< "$(parse_log "$log")"
  note=""
  if [ "${retried[$i]:-0}" = "1" ]; then
    note="retried flaky file(s)"
    f=0
  fi
  [ "$n" -eq 0 ] && missing=1
  total=$(( total + n ))
  total_fail=$(( total_fail + f ))
  printf '%-10s %8s %9s %8s %7s  %-22s %s\n' "$i" "$(( ends[i] - starts[i] ))" "$n" "$f" "${codes[$i]}" "$note" "$log"
done
printf '%-10s %8s %9s %8s\n' "TOTAL" "$run_wall" "$total" "$total_fail"

echo
echo "wall (runner): ${run_wall}s   tests: ${total}   failures: ${total_fail}   exit: ${rc}"
[ -n "$retried_note" ] && echo "flaky retries (passed on re-run):$retried_note"

if [ "$total_fail" -ne 0 ] || [ "$missing" -ne 0 ]; then
  echo "FAILURES DETECTED — first failure per partition:" >&2
  for ((i=1; i<=PARTITIONS; i++)); do
    grep -n -m3 -E '^\s+[0-9]+\) test ' "$LOG_DIR/partition-$i.log" 2>/dev/null
  done
  rc=1
fi

if [ -n "$EXPECTED_TESTS" ] && [ "$total" -ne "$EXPECTED_TESTS" ]; then
  echo "TEST COUNT MISMATCH: expected $EXPECTED_TESTS, got $total" >&2
  rc=1
fi

exit "$rc"