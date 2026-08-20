#!/usr/bin/env bash
# SessionStart hook. Surfaces the state a session needs to know before touching
# anything: which branch is writable, whether local config exists, and whether
# the verification stamp still certifies the current tree.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWED_BRANCH="${IHA_ALLOWED_PUSH_BRANCH:-claude/irvine-home-analysis-platform-9gvily}"
STAMP="$REPO_ROOT/.verify-stamp"

branch="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo 'detached')"

lines=("Branch: $branch (pushes allowed only to $ALLOWED_BRANCH)")

if [ "$branch" != "$ALLOWED_BRANCH" ]; then
  lines+=("WARNING: not on the designated branch. Switch before making changes.")
fi

if [ -f "$REPO_ROOT/.env" ]; then
  lines+=("Local config: .env present")
else
  lines+=("Local config: .env missing — copy .env.example and fill it in before running deploy or verify against Snowflake.")
fi

if [ -f "$STAMP" ]; then
  stale="$(find "$REPO_ROOT/snowflake" "$REPO_ROOT/ingest" "$REPO_ROOT/app" \
                "$REPO_ROOT/scripts" "$REPO_ROOT/tests" \
                -type f -newer "$STAMP" 2>/dev/null | head -n 1)"
  if [ -n "$stale" ]; then
    lines+=("Verification: STALE — sources changed since the last passing run. scripts/verify.sh must pass before the next commit.")
  else
    lines+=("Verification: current")
  fi
else
  lines+=("Verification: never run. scripts/verify.sh must pass before the first commit.")
fi

printf '%s\n' "${lines[@]}" | jq -Rsc '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("Irvine Home Analysis Platform\n" + .)
  }
}'
exit 0
