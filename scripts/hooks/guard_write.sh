#!/usr/bin/env bash
# PreToolUse guard for Write|Edit. Refuses to create or modify files that would
# put credentials in the repository.
#
# Credentials belong in Snowflake SECRET objects (see
# snowflake/00_setup/04_external_access.sql) or in a gitignored .env — never in
# a tracked file. This repository is public.
#
# FAIL-CLOSED: unparseable payload or missing jq denies rather than allows.
set -uo pipefail

emit_deny() {
  local reason="${1//\\/\\\\}"
  reason="${reason//\"/\\\"}"
  reason="${reason//$'\n'/\\n}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_deny \
  "Blocked: jq is required by the credential guard but is not installed, so this write could not be checked. Install jq. Guards fail closed by design."

payload="$(cat)"
if ! path="$(printf '%s' "$payload" | jq -re '.tool_input.file_path // ""' 2>/dev/null)"; then
  emit_deny "Blocked: could not parse the hook payload, so this write could not be checked for credentials. Guards fail closed by design."
fi
[ -z "$path" ] && exit 0

base="$(basename "$path")"

# .env.example is the committed template and is explicitly permitted.
if [ "$base" != ".env.example" ]; then
  case "$base" in
    .env|.env.*|*.pem|*.p8|*.key|*_rsa|*_rsa.*|credentials.json|connections.toml)
      emit_deny "Blocked: '$base' is a credential file. Claude does not author credential files — copy .env.example to .env and fill it in yourself, or store the value in a Snowflake SECRET object. See CLAUDE.md > Hard constraints."
      ;;
  esac
  case "$base" in
    *_key*|*_secret*|*_token*)
      # Source files may legitimately reference secrets by name (a proc that
      # reads one); files whose name marks them as key material may not.
      case "$base" in
        *.sql|*.py|*.md|*.yaml|*.yml|*.sh|*.toml|*.json) ;;
        *) emit_deny "Blocked: '$base' looks like key material. See CLAUDE.md > Hard constraints." ;;
      esac
      ;;
  esac
fi

# Scan the content being written for literal credentials.
content="$(printf '%s' "$payload" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null || echo "")"
if [ -n "$content" ]; then
  if printf '%s' "$content" | grep -qE 'BEGIN [A-Z ]*PRIVATE KEY'; then
    emit_deny "Blocked: the content contains a private key block. Credentials belong in Snowflake SECRET objects, never in the repo."
  fi
  if printf '%s' "$content" | grep -qiE '(password|passwd|secret|api_?key|token)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"'{$<]{8,}["'"'"']'; then
    emit_deny "Blocked: the content appears to assign a literal credential. Reference a Snowflake SECRET or an environment variable instead. If this is a false positive (e.g. a docs example), use an obvious placeholder like \"<your-token>\"."
  fi
fi

exit 0
