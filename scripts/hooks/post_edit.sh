#!/usr/bin/env bash
# PostToolUse hook for Write|Edit.
#
#   *.sql                      -> lint with sqlfluff (Snowflake dialect)
#   fetching python modules    -> assert robots.txt handling and a User-Agent
#
# The crawl check is the mechanical half of a policy: we crawl politely, and
# "politely" must mean the code demonstrably consults robots.txt. Intent is not
# enforceable; a grep is.
#
# It applies only to modules that ACTUALLY FETCH, and it accepts compliance
# inherited from ingest/adapters/base.py. Centralising the robots gate in a base
# class is better design than copying it into every adapter, so the check must
# recognise that rather than punish it. A pure data module that opens no
# connection is not a crawler and is not checked.
set -uo pipefail

payload="$(cat)"
# CLAUDE.md requires guards to fail closed. This is an advisory PostToolUse hook
# rather than a blocking one, so it surfaces a warning instead of denying — but
# it must not stay silent, which would leave crawl policy unchecked without
# anyone noticing.
if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"jq is not installed, so the crawl-policy and SQL lint checks did not run. Install jq before relying on this gate."}}\n'
  exit 0
fi
path="$(printf '%s' "$payload" | jq -r '.tool_response.filePath // .tool_input.file_path // ""' 2>/dev/null)"
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
  *crawler*.py|*/adapters/*.py|*proc_ingest*.py)
    # Does this module actually make network requests?
    if grep -qE 'urllib\.request|urlopen|requests\.(get|post)|httpx|http\.client' "$path"; then
      # Compliance may be implemented here, or inherited from the adapter base.
      has_robots=0
      grep -qiE 'robots?\.txt|robotparser|robotfileparser|can_fetch' "$path" && has_robots=1
      # Must actually SUBCLASS the adapter, not merely import a name from it.
      # A module that imports SentimentDocument and calls urlopen inherits
      # nothing and was previously passing this check.
      grep -qE 'class[[:space:]]+[A-Za-z_]+\([^)]*SentimentAdapter' "$path" && has_robots=1

      has_ua=0
      grep -qiE 'user.?agent' "$path" && has_ua=1
      grep -qE 'class[[:space:]]+[A-Za-z_]+\([^)]*SentimentAdapter' "$path" && has_ua=1

      if [ "$has_robots" -eq 0 ]; then
        msgs+=("$(basename "$path") fetches remote content but neither consults robots.txt nor inherits from SentimentAdapter. Every fetching adapter must go through a robots.txt gate — see CLAUDE.md > Non-negotiables and docs/data_sources.md.")
      fi
      if [ "$has_ua" -eq 0 ]; then
        msgs+=("$(basename "$path") fetches remote content but sets no User-Agent. Crawlers must identify themselves with a reachable contact address (CRAWLER_CONTACT_EMAIL).")
      fi
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
