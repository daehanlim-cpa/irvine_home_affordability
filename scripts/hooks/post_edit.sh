#!/usr/bin/env bash
# PostToolUse hook for Write|Edit.
#
#   *.sql            -> lint with sqlfluff (Snowflake dialect) if available
#   ingest/*crawler* -> assert the file references robots.txt handling
#
# The crawler check is the mechanical half of a policy: we crawl politely, and
# "politely" means the code demonstrably consults robots.txt. Intent is not
# enforceable; a grep is.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

payload="$(cat)"
path="$(printf '%s' "$payload" | jq -r '.tool_response.filePath // .tool_input.file_path // ""')"
[ -z "$path" ] && exit 0
[ -f "$path" ] || exit 0

msgs=()

case "$path" in
  *.sql)
    if command -v sqlfluff >/dev/null 2>&1; then
      if ! out="$(sqlfluff lint --dialect snowflake "$path" 2>&1)"; then
        msgs+=("sqlfluff findings in $(basename "$path"):"$'\n'"$out")
      fi
    fi
    ;;
esac

case "$path" in
  *crawler*.py|*/adapters/*.py)
    # Matches robots.txt, urllib.robotparser, RobotFileParser, can_fetch.
    if ! grep -qiE 'robots?\.txt|robotparser|robotfileparser|can_fetch' "$path"; then
      msgs+=("$(basename "$path") fetches remote content but never references robots.txt. Every adapter must consult robots.txt before requesting a page — see CLAUDE.md > Non-negotiables and docs/data_sources.md.")
    fi
    if ! grep -qiE 'user.?agent' "$path"; then
      msgs+=("$(basename "$path") does not set a User-Agent. Crawlers must identify themselves with a reachable contact address (CRAWLER_CONTACT_EMAIL).")
    fi
    ;;
esac

if [ ${#msgs[@]} -gt 0 ]; then
  printf '%s\n' "${msgs[@]}" | jq -Rsc '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: .
    }
  }'
fi

exit 0
