#!/usr/bin/env bash
# fm-jev-guard.sh - PreToolUse transport for the Jev dynamic delegation guardrail.
#
# Intercepts Bash tool calls in Firstmate's primary supervisor workspace (w1).
# Allows legitimate supervisory actions (draining wakes, beads, steering workers).
# Denies hands-on implementation, remote SSH, package installations, service
# restarts, and project edits, steering Firstmate to delegate to Second Mates.
# Only the shell and read tool payloads this adapter governs are admitted; every
# other tool transport (browser, MCP, unknown or unnamed) is refused in every
# role because its effects cannot be authenticated as a permitted action here.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-jev-guard.sh [--claude|--cursor]
#   bin/fm-jev-guard.sh --command '<cmd>' [--claude|--cursor]
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0
TOOL=""

usage() {
  cat <<'EOF'
Usage: fm-jev-guard.sh [--command <cmd>] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok/Claude/Cursor/Codex).
Tool payloads other than the exact names Bash, Shell, Read and run_terminal_command
are denied before command extraction in every role.
The shell delegation classifier fires only in the real primary checkout (w1);
it also governs secondmate homes, while task worktrees remain inert.
Exits 0 to allow and 2 to deny commands that violate supervisor delegation boundaries.
The deny reason is written to stderr, with a Grok/Pi decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0.
An unavailable classifier runtime denies commands in supervisor homes.
A malformed payload with no extractable command is ignored (exit 0).
EOF
}

json_escape() {
  local bs='\' dq='"'
  local s=${1//"$bs"/$bs$bs}
  s=${s//"$dq"/$bs$dq}
  printf '%s' "${s//$'\n'/ }"
}

# One deny rendering for every harness protocol: Cursor reads its own object on
# stdout and exit 0; Claude requires empty stdout with the object on stderr;
# Grok/Pi read the decision object on stdout; both of the latter exit 2.
render_deny() {
  local escaped
  escaped=$(json_escape "$1")
  if [ "$CURSOR_MODE" -eq 1 ]; then
    printf '{"permission":"deny","user_message":"%s"}\n' "$escaped"
    exit 0
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

PAYLOAD=""
if [ "$CMD_SET" -eq 0 ]; then
  IFS= read -r -d '' PAYLOAD || true
  [ -n "$PAYLOAD" ] || exit 0
fi

SCRIPT_DIR=$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P) || render_deny "[require_delegation] classifier runtime unavailable"
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || render_deny "[require_delegation] classifier runtime unavailable"

# Scope check: apply only in the primary checkout (git-dir == git-common-dir).
# Crewmate / scout task worktrees (linked git worktrees) are inert (exit 0) only
# when git positively identifies the linked worktree; a context that cannot be
# established fails closed. Secondmate homes are supervisors too and use the
# same delegation policy.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || render_deny "[require_delegation] classifier runtime unavailable"
if [ "${FM_TEST_PRIMARY:-0}" -ne 1 ] && [ ! -f "$FM_ROOT/.fm-secondmate-home" ] \
  && [ ! -f "${FM_HOME:-}/.fm-secondmate-home" ]; then
  GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || render_deny "[require_delegation] classifier runtime unavailable"
  GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || render_deny "[require_delegation] classifier runtime unavailable"
  [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
fi

if [ "$CMD_SET" -eq 0 ]; then
  command -v jq >/dev/null 2>&1 || render_deny "[require_delegation] classifier runtime unavailable"
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty) | select(type=="string")' 2>/dev/null) || exit 0
  # No click label, session, command field or caller-supplied action class can
  # prove what an unlisted tool will send. Deny every transport that is not one
  # of the governed shell/read tools rather than letting it bypass mail_send
  # through the shell-command empty-input fast path.
  case "$TOOL" in
    Bash|Shell|Read|run_terminal_command) ;;
    *) render_deny "fm-action-gate: DENY: tool transport '${TOOL:-unnamed}' has no approved action adapter; mail_send is prohibited" ;;
  esac

  HOOK_LIB="$SCRIPT_DIR/fm-hook-host-lib.sh"
  if [ -f "$HOOK_LIB" ]; then
    # shellcheck source=bin/fm-hook-host-lib.sh
    . "$HOOK_LIB"
    if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
      exit 0
    fi
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

GUARD_PY="$FM_ROOT/bin/fm-jev-guard.py"
command -v python3 >/dev/null 2>&1 || render_deny "[require_delegation] classifier runtime unavailable"
[ -f "$GUARD_PY" ] || render_deny "[require_delegation] classifier unavailable"

# Invoke python guard engine with --check-only
POLICY_OUTPUT=$(python3 "$GUARD_PY" --command "$CMD" --check-only) || render_deny "[require_delegation] classifier failed"
[ -n "$POLICY_OUTPUT" ] || render_deny "[require_delegation] classifier returned no decision"

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0

REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}

REST2=${REST#*"$TAB"}
REASON=${REST2%%"$TAB"*}

REST3=${REST2#*"$TAB"}
DOMAIN=${REST3%%"$TAB"*}
SUGGESTED=${REST3#*"$TAB"}

if [ -n "$SUGGESTED" ] && [ "$SUGGESTED" != "$REST3" ]; then
  DETAIL="[$CODE] $REASON (Domain: $DOMAIN; Suggested: $SUGGESTED)"
elif [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$REST3" ]; then
  DETAIL="[$CODE] $REASON (Domain: $DOMAIN)"
else
  DETAIL="[$CODE] $REASON"
fi

render_deny "$DETAIL"
