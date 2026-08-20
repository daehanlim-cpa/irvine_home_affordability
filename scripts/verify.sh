#!/usr/bin/env bash
# Pre-push verification gate.
#
#   scripts/verify.sh           full gate, including Snowflake-side checks
#   scripts/verify.sh --fast    local checks only, no Cortex spend
#
# Writes .verify-stamp on success. The PreToolUse commit hook refuses to commit
# without a stamp that is newer than every source file, so this is the gate, not
# a suggestion.
#
# Checks that cannot run in the current environment report SKIP with the reason.
# A SKIP is not a PASS — it is recorded and printed so nobody mistakes an
# unrunnable check for a satisfied one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

RESULTS=()
FAILED=0
SKIPPED=0

pass()  { RESULTS+=("PASS|$1|${2:-}"); }
fail()  { RESULTS+=("FAIL|$1|${2:-}"); FAILED=$((FAILED + 1)); }
skip()  { RESULTS+=("SKIP|$1|${2:-}"); SKIPPED=$((SKIPPED + 1)); }

# Load local config if present (never committed).
[ -f .env ] && set -a && . ./.env 2>/dev/null && set +a

# --------------------------------------------------------------------------
# 1. Shell and Python syntax
# --------------------------------------------------------------------------
syntax_errs=""
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || syntax_errs="$syntax_errs $f"
done < <(find scripts -name '*.sh' -type f 2>/dev/null)

while IFS= read -r f; do
  python3 -m py_compile "$f" 2>/dev/null || syntax_errs="$syntax_errs $f"
done < <(find ingest app tests -name '*.py' -type f 2>/dev/null)
find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null

if [ -n "$syntax_errs" ]; then
  fail "syntax" "errors in:$syntax_errs"
else
  pass "syntax" "shell + python parse clean"
fi

# --------------------------------------------------------------------------
# 2. Source registry is valid YAML with the fields the ingest layer requires
# --------------------------------------------------------------------------
if [ -f ingest/sources.yaml ]; then
  if python3 - <<'PY' 2>/dev/null
import sys, yaml
REQUIRED = {"name", "kind", "url", "rate_limit_rps", "daily_call_cap", "compliance"}
doc = yaml.safe_load(open("ingest/sources.yaml"))
srcs = doc.get("sources") or []
if not srcs:
    sys.exit("no sources defined")
for s in srcs:
    missing = REQUIRED - set(s)
    if missing:
        sys.exit(f"{s.get('name','<unnamed>')} missing {sorted(missing)}")
PY
  then
    pass "source-registry" "$(python3 -c 'import yaml;print(len(yaml.safe_load(open("ingest/sources.yaml"))["sources"]))' 2>/dev/null) sources, all with rate limits and compliance records"
  else
    fail "source-registry" "$(python3 - <<'PY' 2>&1 | tail -1
import sys, yaml
REQUIRED = {"name", "kind", "url", "rate_limit_rps", "daily_call_cap", "compliance"}
doc = yaml.safe_load(open("ingest/sources.yaml"))
for s in (doc.get("sources") or []):
    missing = REQUIRED - set(s)
    if missing:
        print(f"{s.get('name','<unnamed>')} missing {sorted(missing)}")
PY
)"
  fi
else
  skip "source-registry" "ingest/sources.yaml not created yet"
fi

# --------------------------------------------------------------------------
# 3. Hard-constraint hooks still behave
# --------------------------------------------------------------------------
if [ -x scripts/hooks/test_hooks.sh ]; then
  if out="$(scripts/hooks/test_hooks.sh 2>&1)"; then
    pass "hooks" "$(printf '%s' "$out" | tail -1 | sed 's/^ *//')"
  else
    fail "hooks" "$(printf '%s' "$out" | tail -3)"
  fi
else
  fail "hooks" "scripts/hooks/test_hooks.sh missing or not executable"
fi

# --------------------------------------------------------------------------
# 3a. Golden-address seed is in sync with its YAML source
#     A generated file that has drifted from its source is worse than no
#     generated file: the tests would assert against addresses nobody chose.
# --------------------------------------------------------------------------
if [ -f tests/fixtures/golden_addresses.yaml ]; then
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    before="$(cat tests/seed_golden_addresses.sql 2>/dev/null || echo '')"
    if gen_out="$(python3 scripts/gen_golden_seed.py 2>&1)"; then
      after="$(cat tests/seed_golden_addresses.sql 2>/dev/null || echo '')"
      if [ "$before" = "$after" ]; then
        pass "golden-seed" "$(printf '%s' "$gen_out" | tail -1)"
      else
        fail "golden-seed" "tests/seed_golden_addresses.sql was stale and has been regenerated. Review and commit it."
      fi
    else
      # Placeholder addresses still present is a real, actionable state.
      skip "golden-seed" "$(printf '%s' "$gen_out" | head -2)"
    fi
  else
    skip "golden-seed" "PyYAML not installed"
  fi
else
  skip "golden-seed" "no fixture file"
fi

# --------------------------------------------------------------------------
# 3b. Python unit tests (ingest logic: rate limiting, robots fail-closed,
#     payload hashing). No Snowflake required, so they always run.
# --------------------------------------------------------------------------
if python3 -c 'import pytest' >/dev/null 2>&1; then
  if find tests -name 'test_*.py' -type f 2>/dev/null | head -1 | grep -q .; then
    if out="$(python3 -m pytest tests/ -q 2>&1)"; then
      pass "python-tests" "$(printf '%s' "$out" | tail -1)"
    else
      fail "python-tests" "$(printf '%s' "$out" | tail -12)"
    fi
  else
    skip "python-tests" "no tests/test_*.py yet"
  fi
else
  skip "python-tests" "pytest not installed (pip install -r requirements-dev.txt)"
fi

# --------------------------------------------------------------------------
# 4. CLAUDE.md stays concise
#    The rule "adding a learning means pruning one" is only real if something
#    enforces the cap.
# --------------------------------------------------------------------------
if [ -f CLAUDE.md ]; then
  lines="$(wc -l < CLAUDE.md | tr -d ' ')"
  if [ "$lines" -le 160 ]; then
    pass "claude-md" "$lines lines (cap 160)"
  else
    fail "claude-md" "$lines lines exceeds the 160-line cap — prune a stale entry before adding a new one"
  fi
else
  fail "claude-md" "CLAUDE.md missing"
fi

# --------------------------------------------------------------------------
# 5. No credentials in tracked files
# --------------------------------------------------------------------------
secret_hits=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in .env.example|docs/*) continue;; esac
    if grep -qE 'BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null; then
      secret_hits="$secret_hits $f(private-key)"
    fi
    if grep -qiE '(password|api_?key|secret|token)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"'{$<]{8,}["'"'"']' "$f" 2>/dev/null; then
      secret_hits="$secret_hits $f(literal)"
    fi
  done < <( { git ls-files 2>/dev/null; git diff --cached --name-only 2>/dev/null; } | sort -u )
fi
if [ -n "$secret_hits" ]; then
  fail "no-secrets" "possible credentials in:$secret_hits"
else
  pass "no-secrets" "no credential literals in tracked files"
fi

# --------------------------------------------------------------------------
# 6. SQL lint
# --------------------------------------------------------------------------
if command -v sqlfluff >/dev/null 2>&1; then
  if find snowflake -name '*.sql' -type f 2>/dev/null | head -1 | grep -q .; then
    if out="$(sqlfluff lint --dialect snowflake snowflake/ 2>&1)"; then
      pass "sql-lint" "clean"
    else
      fail "sql-lint" "$(printf '%s' "$out" | tail -15)"
    fi
  else
    skip "sql-lint" "no .sql files yet"
  fi
else
  skip "sql-lint" "sqlfluff not installed (pip install sqlfluff)"
fi

# --------------------------------------------------------------------------
# 7. Snowflake-side checks
#    Cortex probe, golden addresses, score reproducibility, narrative
#    groundedness, and per-request cost. These spend credits, so --fast skips
#    them deliberately rather than by accident.
# --------------------------------------------------------------------------
# Each entry runs a script that must SELECT its results. Pointing a check at a
# file that only creates objects makes it pass vacuously — the check reports
# green while asserting nothing, which is worse than not having it. The
# assertion scripts below are generated at run time so each check actually
# queries its gate view.
SF_CHECKS=(
  "cortex-probe:snowflake/00_setup/05_cortex_probe.sql"
  "golden-addresses:__ASSERT__SELECT CHECK_NAME, STATUS, DETAIL FROM MART.VW_SCORING_TESTS;"
  "score-reproducibility:__ASSERT__CALL MART.SP_TEST_REPRODUCIBILITY();"
  "groundedness:__ASSERT__CALL MART.SP_EVALUATE_NARRATIVES(); SELECT METRIC_NAME, STATUS, DETAIL FROM MART.VW_EVAL_GATE;"
  "cost-regression:__ASSERT__SELECT THRESHOLD_NAME, IFF(IS_BREACHED, 'FAIL', 'PASS') AS STATUS, 'credits=' || CREDITS_USED FROM OPS.VW_SPEND_VS_THRESHOLD;"
)

# Resolve HOW SQL is executed. requirements-dev.txt pins the connector but not
# the CLI, so assuming `snow` makes every Snowflake check fail with "command not
# found" on a correctly provisioned machine.
SF_RUNNER=""
sf_available() {
  [ -n "${SNOWFLAKE_ACCOUNT:-}" ] || return 1
  if command -v snow >/dev/null 2>&1; then SF_RUNNER="snow"; return 0; fi
  if python3 -c 'import snowflake.connector' >/dev/null 2>&1; then SF_RUNNER="python"; return 0; fi
  return 1
}

sf_exec() {
  case "$SF_RUNNER" in
    snow)   snow sql -f "$1" 2>&1 ;;
    python) python3 "$REPO_ROOT/scripts/sf_exec.py" "$1" 2>&1 ;;
    *)      echo "no Snowflake runner resolved"; return 2 ;;
  esac
}

if [ "$FAST" -eq 1 ]; then
  for c in "${SF_CHECKS[@]}"; do
    skip "${c%%:*}" "--fast: Snowflake checks skipped (no Cortex spend)"
  done
elif ! sf_available; then
  reason="no Snowflake connection"
  [ -z "${SNOWFLAKE_ACCOUNT:-}" ] && reason="SNOWFLAKE_ACCOUNT unset — copy .env.example to .env"
  if ! command -v snow >/dev/null 2>&1 && ! python3 -c 'import snowflake.connector' >/dev/null 2>&1; then
    reason="neither the 'snow' CLI nor snowflake-connector-python is installed (pip install -r requirements-dev.txt)"
  fi
  for c in "${SF_CHECKS[@]}"; do
    skip "${c%%:*}" "$reason"
  done
else
  for c in "${SF_CHECKS[@]}"; do
    name="${c%%:*}"; script="${c#*:}"
    cleanup_sql=""
    case "$script" in
      __ASSERT__*)
        # Materialise the assertion into a temp file so sf_exec can run it.
        cleanup_sql="$(mktemp "${TMPDIR:-/tmp}/iha_assert_XXXXXX.sql")"
        printf '%s\n' "${script#__ASSERT__}" > "$cleanup_sql"
        script="$cleanup_sql"
        ;;
      *)
        if [ ! -f "$script" ]; then
          skip "$name" "$script not created yet"
          continue
        fi
        ;;
    esac
    if out="$(sf_exec "$script")"; then
      if printf '%s' "$out" | grep -qiE '\bFAIL\b'; then
        fail "$name" "$(printf '%s' "$out" | grep -iE '\bFAIL\b' | head -5)"
      else
        pass "$name" "ok"
      fi
    else
      fail "$name" "$(printf '%s' "$out" | tail -5)"
    fi
    [ -n "$cleanup_sql" ] && rm -f "$cleanup_sql"
  done
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo
printf '%-24s %s\n' "CHECK" "RESULT"
printf '%s\n' "------------------------------------------------------------"
for r in "${RESULTS[@]}"; do
  status="${r%%|*}"; rest="${r#*|}"; name="${rest%%|*}"; detail="${rest#*|}"
  printf '%-24s %-5s %s\n' "$name" "$status" "$detail"
done
printf '%s\n' "------------------------------------------------------------"

if [ "$FAILED" -gt 0 ]; then
  echo "GATE FAILED: $FAILED check(s) failed, $SKIPPED skipped. No stamp written."
  rm -f .verify-stamp
  exit 1
fi

date -u +'%Y-%m-%dT%H:%M:%SZ' > .verify-stamp
if [ "$SKIPPED" -gt 0 ]; then
  echo "GATE PASSED with $SKIPPED skipped check(s). Stamp written."
  echo "Skipped checks are NOT verified — review the reasons above before relying on this run."
else
  echo "GATE PASSED: all checks green. Stamp written."
fi
exit 0
