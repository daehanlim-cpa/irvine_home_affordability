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
SF_CHECKS=(
  "cortex-probe:snowflake/00_setup/05_cortex_probe.sql"
  "golden-addresses:tests/test_scoring.sql"
  "score-reproducibility:tests/test_scoring.sql"
  "groundedness:snowflake/40_cortex/ai_observability_evals.sql"
  "cost-regression:snowflake/70_ops/vw_cortex_spend.sql"
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
    if [ ! -f "$script" ]; then
      skip "$name" "$script not created yet"
      continue
    fi
    if out="$(sf_exec "$script")"; then
      if printf '%s' "$out" | grep -qiE '\bFAIL\b'; then
        fail "$name" "$(printf '%s' "$out" | grep -iE '\bFAIL\b' | head -5)"
      else
        pass "$name" "ok"
      fi
    else
      fail "$name" "$(printf '%s' "$out" | tail -5)"
    fi
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
