#!/usr/bin/env bash
# Regression suite for the hard-constraint hooks.
#
# The hooks are the only thing standing between a careless command and a
# destructive one, so they get tested like production code. Run by
# scripts/verify.sh on every gate.
#
# Cases marked [review] were bypasses found by independent code review of the
# first implementation. Each is now a permanent test.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0

# Assembled at runtime so the literal header never appears in this file and the
# no-secrets scan in verify.sh does not flag its own test fixture. [review]
RSA_="RSA "
KEY_HEADER="-----BEGIN ${RSA_}PRIVATE KEY-----"

run_hook() { printf '%s' "$2" | "$HOOK_DIR/$1" 2>/dev/null; }

assert_deny() {
  local name="$1" out
  out="$(run_hook "$2" "$3")"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "  FAIL [$name]: expected deny, got: ${out:-<empty>}"
  fi
}

assert_allow() {
  local name="$1" out
  out="$(run_hook "$2" "$3")"
  if [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "  FAIL [$name]: expected no decision, got: $out"
  fi
}

assert_warns() {
  local name="$1" needle="$4" out
  out="$(run_hook "$2" "$3")"
  if printf '%s' "$out" | jq -re '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -qi "$needle"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "  FAIL [$name]: expected warning matching '$needle', got: ${out:-<empty>}"
  fi
}

# ---------------------------------------------------------------- push guard
assert_deny  "push to main"            guard_bash.sh '{"tool_input":{"command":"git push -u origin main"}}'
assert_deny  "push to arbitrary"       guard_bash.sh '{"tool_input":{"command":"git push origin feature/x"}}'
assert_deny  "push --all [review]"     guard_bash.sh '{"tool_input":{"command":"git push --all origin"}}'
assert_deny  "push --mirror [review]"  guard_bash.sh '{"tool_input":{"command":"git push --mirror origin"}}'
assert_deny  "push --tags [review]"    guard_bash.sh '{"tool_input":{"command":"git push --tags origin"}}'
assert_deny  "git -C push [review]"    guard_bash.sh '{"tool_input":{"command":"git -C . push origin main"}}'
assert_deny  "git-dir push [review]"   guard_bash.sh '{"tool_input":{"command":"git --git-dir=.git push origin main"}}'
assert_deny  "push after && [review]"  guard_bash.sh '{"tool_input":{"command":"cd /tmp && git push origin main"}}'
assert_deny  "refspec to main"         guard_bash.sh '{"tool_input":{"command":"git push origin HEAD:refs/heads/main"}}'
assert_deny  "force push to main"      guard_bash.sh '{"tool_input":{"command":"git push origin +main"}}'
assert_allow "push to designated"      guard_bash.sh '{"tool_input":{"command":"git push -u origin claude/irvine-home-analysis-platform-9gvily"}}'

# ------------------------------------------------------------ destructive SQL
assert_deny  "snow drop prod schema"   guard_bash.sh '{"tool_input":{"command":"snow sql -q \"DROP SCHEMA IRVINE_HOME_ANALYSIS.MART;\""}}'
assert_deny  "snowsql drop database"   guard_bash.sh '{"tool_input":{"command":"snowsql -q \"DROP DATABASE IRVINE_HOME_ANALYSIS;\""}}'
assert_deny  "truncate prod table"     guard_bash.sh '{"tool_input":{"command":"snow sql -q \"TRUNCATE TABLE MART.DIM_PARCEL;\""}}'
assert_deny  "newline-split DDL [review]" guard_bash.sh '{"tool_input":{"command":"snow sql -q \"DROP SCHEMA\n  IRVINE_HOME_ANALYSIS.MART;\""}}'
assert_deny  "quoted object name"      guard_bash.sh '{"tool_input":{"command":"snow sql -q \"DROP SCHEMA \"MART\";\""}}'
assert_allow "drop dev schema"         guard_bash.sh '{"tool_input":{"command":"snow sql -q \"DROP SCHEMA MART_DEV;\""}}'
# Mentioning destructive DDL is not executing it. Blocking greps and tests cost
# real work and prevented nothing, since the risk is execution. [review]
assert_allow "grep mentions DDL"       guard_bash.sh '{"tool_input":{"command":"grep -rn \"DROP SCHEMA\" snowflake/"}}'
assert_allow "unrelated command"       guard_bash.sh '{"tool_input":{"command":"ls -la"}}'

# ------------------------------------------- heredoc bodies are data [review]
assert_allow "heredoc mentions push"   guard_bash.sh '{"tool_input":{"command":"cat > doc.md <<'"'"'EOF'"'"'\nRun: git push origin main\nEOF"}}'
assert_allow "heredoc mentions drop"   guard_bash.sh '{"tool_input":{"command":"cat > t.sql <<'"'"'EOF'"'"'\nDROP SCHEMA PROD;\nEOF"}}'

# ------------------------------------------------------------ credential guard
assert_deny  "write .env"              guard_write.sh '{"tool_input":{"file_path":"/x/.env","content":"a"}}'
assert_deny  "write private key file"  guard_write.sh '{"tool_input":{"file_path":"/x/id_rsa","content":"a"}}'
assert_deny  "private key content"     guard_write.sh "{\"tool_input\":{\"file_path\":\"/x/a.txt\",\"content\":\"${KEY_HEADER}\"}}"
assert_deny  "literal secret"          guard_write.sh '{"tool_input":{"file_path":"/x/a.py","content":"api_key = \"sk_live_abcdefghijkl\""}}'
assert_allow "env template"            guard_write.sh '{"tool_input":{"file_path":"/x/.env.example","content":"SNOWFLAKE_USER="}}'
assert_allow "placeholder secret"      guard_write.sh '{"tool_input":{"file_path":"/x/a.py","content":"api_key = \"<your-key>\""}}'
assert_allow "ordinary sql"            guard_write.sh '{"tool_input":{"file_path":"/x/a.sql","content":"SELECT 1;"}}'

# -------------------------------------------------- fail-closed behaviour [review]
# A guard that allows the command when it cannot evaluate it is not a guard.
for g in guard_bash.sh guard_write.sh; do
  out="$(printf 'not json at all' | "$HOOK_DIR/$g" 2>/dev/null)"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "  FAIL [$g fails closed on bad payload]: got ${out:-<empty>}"
  fi
done

out="$(printf '%s' '{"tool_input":{"command":"git push origin main"}}' \
      | env PATH=/nonexistent /bin/bash "$HOOK_DIR/guard_bash.sh" 2>/dev/null)"
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "  FAIL [guard_bash fails closed without jq]: got ${out:-<empty>}"
fi

# --------------------------------------------------------------- crawl policy
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/adapters"
printf 'import urllib.request\nurllib.request.urlopen(url)\n' > "$TMP/adapters/bad_crawler.py"
printf 'import urllib.robotparser\nimport urllib.request\nUSER_AGENT="x"\nrp=urllib.robotparser.RobotFileParser()\nrp.can_fetch(USER_AGENT,url)\nurllib.request.urlopen(url)\n' > "$TMP/adapters/good_crawler.py"
# Compliance centralised in a base class is better design than copied into every
# adapter, so the check must accept inheritance. [review]
printf 'from base import SentimentAdapter\nimport urllib.request\nclass X(SentimentAdapter):\n    pass\n' > "$TMP/adapters/inherits.py"
# A module that opens no connection is not a crawler and must not be flagged.
printf 'ALIASES = {"Woodbridge": "WOODBRIDGE"}\n' > "$TMP/adapters/pure_data.py"

assert_warns "fetcher without robots"   post_edit.sh "{\"tool_input\":{\"file_path\":\"$TMP/adapters/bad_crawler.py\"}}" "robots.txt"
assert_allow "fetcher with robots"      post_edit.sh "{\"tool_input\":{\"file_path\":\"$TMP/adapters/good_crawler.py\"}}"
assert_allow "inherited compliance"     post_edit.sh "{\"tool_input\":{\"file_path\":\"$TMP/adapters/inherits.py\"}}"
assert_allow "pure data module"         post_edit.sh "{\"tool_input\":{\"file_path\":\"$TMP/adapters/pure_data.py\"}}"

echo "  hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
