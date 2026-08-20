#!/usr/bin/env bash
# PreToolUse guard for Bash. Reads the hook payload on stdin and denies commands
# that violate a hard constraint. Emits a PreToolUse permission decision as JSON.
#
# Constraints enforced:
#   1. git push only to the designated branch
#   2. no DROP DATABASE / DROP SCHEMA / TRUNCATE against non-*_DEV objects
#   3. git commit requires a fresh scripts/verify.sh stamp
#
# Two design rules learned the hard way, both from this guard blocking
# legitimate work:
#
#   FAIL CLOSED. If the payload cannot be parsed, or jq is unavailable, deny.
#   A guard that fails open is not a guard.
#
#   ANALYSE THE COMMAND, NOT THE PAYLOAD. Heredoc bodies and file contents are
#   data, not commands. Writing a file that mentions "git push" is not a push,
#   and a test fixture naming DROP SCHEMA is not a drop. Matching raw text
#   blocks real work without preventing anything, because the risk is
#   execution, not mention. Content is covered separately by guard_write.sh
#   and the no-secrets scan in verify.sh.
set -uo pipefail

ALLOWED_BRANCH="${IHA_ALLOWED_PUSH_BRANCH:-claude/irvine-home-analysis-platform-9gvily}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAMP="$REPO_ROOT/.verify-stamp"

emit_deny() {
  # Hand-rolled JSON so this still works when jq is the missing dependency.
  local reason="${1//\\/\\\\}"
  reason="${reason//\"/\\\"}"
  reason="${reason//$'\n'/\\n}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_deny \
  "Blocked: jq is required by the hard-constraint guards but is not installed, so this command could not be checked. Install jq (apt-get install jq / brew install jq). Guards fail closed by design."

payload="$(cat)"
if ! cmd="$(printf '%s' "$payload" | jq -re '.tool_input.command // ""' 2>/dev/null)"; then
  emit_deny "Blocked: could not parse the hook payload, so this command could not be checked against the hard constraints. Guards fail closed by design."
fi
[ -z "$cmd" ] && exit 0

# --------------------------------------------------------------- normalisation
# Drop heredoc bodies: everything from a `<<`/`<<-` operator to its terminator
# is data being written, not commands being run.
strip_heredocs() {
  awk '
    BEGIN { in_doc = 0 }
    {
      if (in_doc) { if ($0 == term || $0 == term ";") { in_doc = 0 }; next }
      line = $0
      if (match(line, /<<-?[[:space:]]*'"'"'?"?[A-Za-z_][A-Za-z0-9_]*'"'"'?"?/)) {
        t = substr(line, RSTART, RLENGTH)
        gsub(/<<-?[[:space:]]*/, "", t); gsub(/['"'"'"]/, "", t)
        term = t; in_doc = 1
      }
      print line
    }
  '
}

cmd_only="$(printf '%s' "$cmd" | strip_heredocs)"
# Collapse whitespace so a statement split across lines reads the same as one line.
flat="$(printf '%s' "$cmd_only" | tr '\n\t' '  ' | tr -s ' ')"

# A `git`/`snow` token only counts when it starts a command: at the beginning of
# the string, or after a shell operator (; & | && || newline) or an opening paren.
cmd_start='(^|[;&|(]|&&|\|\|)[[:space:]]*'
# Git's global options may appear before the subcommand, and several take a
# separate value (`git -C <dir> push`). Enumerating them explicitly keeps the
# match precise; a permissive [^ ]* here would swallow the subcommand itself.
git_global_opt='(-[cC][[:space:]]+[^[:space:]]+|--(git-dir|work-tree|namespace|exec-path|config-env)([=[:space:]])[^[:space:]]+|--(no-pager|bare|paginate|literal-pathspecs|no-replace-objects)|-p)'
git_invocation="${cmd_start}git([[:space:]]+${git_global_opt})*[[:space:]]+"

# ---------------------------------------------------------------- 1. push guard
if printf '%s' "$flat" | grep -qE "${git_invocation}push([[:space:]]|$)"; then

  # Bulk pushes name no branch and can carry arbitrary refs, so they cannot be
  # verified against the policy and are refused outright.
  if printf '%s' "$flat" | grep -qE '[[:space:]]--(all|mirror|tags)([[:space:]]|$)'; then
    emit_deny "Blocked: bulk push (--all/--mirror/--tags) cannot be verified against the branch policy and would push refs other than '$ALLOWED_BRANCH'. Push the branch explicitly: git push -u origin $ALLOWED_BRANCH"
  fi

  push_args="$(printf '%s' "$flat" | sed -E 's/.*[[:space:]]push[[:space:]]*//')"
  targets="$(printf '%s' "$push_args" \
    | tr ' ' '\n' \
    | grep -vE '^(-.*|origin|upstream|[A-Za-z0-9_.-]+\.git|https?:.*|git@.*|)$' || true)"

  if [ -z "$targets" ]; then
    targets="$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo '')"
    if [ -z "$targets" ]; then
      emit_deny "Blocked: could not determine which branch this push targets (detached HEAD, no explicit refspec). Push explicitly: git push -u origin $ALLOWED_BRANCH"
    fi
  fi

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    dst="${ref##*:}"          # src:dst refspec -> destination
    dst="${dst#refs/heads/}"
    dst="${dst#+}"            # force-push marker
    if [ "$dst" != "$ALLOWED_BRANCH" ]; then
      emit_deny "Blocked: push targets '$dst' but this project may only push to '$ALLOWED_BRANCH'. See CLAUDE.md > Hard constraints."
    fi
  done <<< "$targets"
fi

# ------------------------------------------------------- 2. destructive SQL guard
# Scoped to commands that actually execute SQL against Snowflake.
if printf '%s' "$flat" | grep -qE "${cmd_start}(snow|snowsql)([[:space:]]|$)|snowflake\.connector|snowpark|Session\.builder"; then
  if printf '%s' "$flat" | grep -qiE 'DROP[[:space:]]+(DATABASE|SCHEMA)|TRUNCATE([[:space:]]+TABLE)?[[:space:]]'; then
    while IFS= read -r stmt; do
      [ -z "$stmt" ] && continue
      obj="$(printf '%s' "$stmt" \
        | sed -E 's/.*(DROP[[:space:]]+(DATABASE|SCHEMA)|TRUNCATE([[:space:]]+TABLE)?)[[:space:]]+//I' \
        | sed -E 's/(IF[[:space:]]+EXISTS[[:space:]]+)//I' \
        | awk '{print $1}' | tr -d '"`;'"'")"
      if [ -z "$obj" ]; then
        emit_deny "Blocked: a destructive statement was detected but its target could not be identified. Name the object explicitly."
      fi
      if ! printf '%s' "$obj" | grep -qiE '_DEV(\.|$)'; then
        emit_deny "Blocked: destructive statement targets '$obj', which is not a *_DEV object. Destructive DDL is restricted to development objects. See CLAUDE.md > Hard constraints."
      fi
    done < <(printf '%s' "$flat" | grep -oiE '(DROP[[:space:]]+(DATABASE|SCHEMA)|TRUNCATE([[:space:]]+TABLE)?)[[:space:]]+[^;]*')
  fi
fi

# ------------------------------------------------------------- 3. verify stamp
if printf '%s' "$flat" | grep -qE "${git_invocation}commit([[:space:]]|$)"; then
  if [ ! -f "$STAMP" ]; then
    emit_deny "Blocked: no verification stamp. Run scripts/verify.sh and let it pass before committing. See CLAUDE.md > Hard constraints."
  fi
  newer="$(find "$REPO_ROOT/snowflake" "$REPO_ROOT/ingest" "$REPO_ROOT/app" \
                "$REPO_ROOT/scripts" "$REPO_ROOT/tests" \
                -type f -newer "$STAMP" -not -name '*.pyc' 2>/dev/null | head -n 3)"
  if [ -n "$newer" ]; then
    emit_deny "Blocked: verification stamp is stale — these files changed after the last passing run:
$newer
Re-run scripts/verify.sh before committing."
  fi
fi

exit 0
