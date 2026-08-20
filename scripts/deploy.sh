#!/usr/bin/env bash
# Deploy Snowflake objects in dependency order.
#
#   scripts/deploy.sh                 # everything, in order
#   scripts/deploy.sh --setup-only    # just 00_setup/01-05 (the first run)
#   scripts/deploy.sh --from 30_mart  # resume from a directory
#   scripts/deploy.sh --dry-run       # list what would run, touch nothing
#
# Directory-then-filename order IS the dependency order, so this simply walks
# snowflake/**/*.sql. Each file sets its own USE ROLE, so no role juggling is
# needed here.
#
# Stops at the first failure. A half-deployed schema is easier to reason about
# than one where later objects were created against earlier failures.
#
# Credentials come from .env (gitignored). This script never takes them as
# arguments — a credential on a command line lands in shell history.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SETUP_ONLY=0
DRY_RUN=0
FROM_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --setup-only) SETUP_ONLY=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --from)       FROM_DIR="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -f .env ] && set -a && . ./.env 2>/dev/null && set +a

# --- resolve a runner ---------------------------------------------------------
RUNNER=""
if command -v snow >/dev/null 2>&1; then
  RUNNER="snow"
elif python3 -c 'import snowflake.connector' >/dev/null 2>&1; then
  RUNNER="python"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "$RUNNER" ]; then
    cat >&2 <<'MSG'
No Snowflake runner found.

  pip install -r requirements-dev.txt      # installs snowflake-connector-python

or install the Snowflake CLI (`snow`). Then re-run.

If you would rather not install anything, run the files by hand in Snowsight —
see the printed order below with --dry-run.
MSG
    exit 1
  fi
  if [ -z "${SNOWFLAKE_ACCOUNT:-}" ]; then
    echo "SNOWFLAKE_ACCOUNT is not set. Copy .env.example to .env and fill it in." >&2
    exit 1
  fi
fi

run_file() {
  case "$RUNNER" in
    snow)   snow sql -f "$1" 2>&1 ;;
    python) python3 "$REPO_ROOT/scripts/sf_exec.py" "$1" 2>&1 ;;
  esac
}

# --- collect files in dependency order ---------------------------------------
mapfile -t FILES < <(find snowflake -name '*.sql' -type f | sort)

# The golden-address seed runs after the app layer, because it resolves each
# fixture through APP.FN_RESOLVE_ADDRESS — the product's own geocoder, so a
# resolution regression shows up here rather than being hidden by hard-coded APNs.
if [ -f tests/seed_golden_addresses.sql ]; then
  FILES+=("tests/seed_golden_addresses.sql")
fi

if [ "$SETUP_ONLY" -eq 1 ]; then
  # 01-05 only: create the account objects, then STOP at the probe. Everything
  # downstream depends on what the probe reports, so running past it blind is
  # how you discover a region problem three layers deep instead of immediately.
  mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | grep -E '00_setup/0[1-5]_')
fi

if [ -n "$FROM_DIR" ]; then
  mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | awk -v d="$FROM_DIR" 'index($0, d) {found=1} found')
fi

echo "Deploying ${#FILES[@]} file(s) to ${SNOWFLAKE_ACCOUNT:-<dry-run>}"
echo

failed=0
for f in "${FILES[@]}"; do
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would run  %s\n' "$f"
    continue
  fi

  printf '  %-52s ' "$f"
  if out="$(run_file "$f")"; then
    # The probe and test scripts report failure in a result column rather than
    # by raising, so a clean exit is not by itself a pass.
    if printf '%s' "$out" | grep -qE '\bFAIL\b'; then
      echo "FAIL"
      printf '%s\n' "$out" | grep -E '\bFAIL\b' | sed 's/^/      /' | head -10
      failed=1
      break
    fi
    echo "ok"
  else
    echo "ERROR"
    printf '%s\n' "$out" | tail -15 | sed 's/^/      /'
    failed=1
    break
  fi
done

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run. Nothing was executed."
  exit 0
fi

if [ "$failed" -eq 1 ]; then
  echo "Deployment stopped at the first failure. Fix it and re-run with"
  echo "  scripts/deploy.sh --from <directory>"
  exit 1
fi

if [ "$SETUP_ONLY" -eq 1 ]; then
  cat <<'MSG'
Setup complete through the capability probe.

Review the probe output above before going further — it reports which Cortex
functions resolve in your region, whether your edition supports Data Metric
Functions, and whether cost telemetry is readable. Then:

  scripts/deploy.sh --from 00_setup/06
MSG
else
  echo "Deployment complete. Tasks are created SUSPENDED by design — resume them"
  echo "only after inspecting a manual ingest run (see snowflake/80_orch/tasks.sql)."
fi
