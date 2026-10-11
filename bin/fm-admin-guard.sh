#!/usr/bin/env bash
# fm-admin-guard.sh - Worker-side deterministic guard against permission-bypass merges.
#
# Hard Rule 2: "Never merge a PR without the captain's explicit word."
# Imperative shorthand in a firstmate steer (such as "land it", "merge it",
# "get it in", or "ship to main") crosses the supervisor/captain boundary and
# never confers merge authority.
#
# When a worker hits a merge refusal or permission error, it must NOT fall back
# to `gh pr merge --admin` or any other permission-bypass merge. This guard
# refuses any `gh pr merge` invocation using `--admin` unless the task brief's
# `## Captain's intent` carries an un-negated line authorizing it.
#
# Supported entry forms:
#   <PreToolUse JSON on stdin> | bin/fm-admin-guard.sh [--claude|--cursor]
#   bin/fm-admin-guard.sh --command '<cmd>' [--claude|--cursor]
#   bin/fm-admin-guard.sh [gh] pr merge ... (wrapper/shim mode)
#
# Exit/output contract:
#   ALLOW - exit 0 (executes real gh in wrapper mode).
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0
IS_GH_WRAPPER=0

case "${0##*/}" in
  gh) IS_GH_WRAPPER=1 ;;
esac

case "${1:-}" in
  gh)
    IS_GH_WRAPPER=1
    shift
    ;;
esac

find_real_gh() {
  local self_path real_path
  self_path="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || d="."
    if [ -x "$d/gh" ]; then
      real_path="$(cd "$d" 2>/dev/null && pwd)/gh"
      if [ "$real_path" != "$self_path" ] && [ "$real_path" != "$0" ]; then
        printf '%s\n' "$real_path"
        return 0
      fi
    fi
  done
  for fb in /usr/bin/gh /usr/local/bin/gh /opt/homebrew/bin/gh; do
    if [ -x "$fb" ] && [ "$fb" != "$self_path" ]; then
      printf '%s\n' "$fb"
      return 0
    fi
  done
  return 1
}

SELF=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null)
FM_ROOT=$(CDPATH='' cd -- "${SELF%/*}/.." 2>/dev/null && pwd -P)
FM_HOME=${FM_HOME:-$FM_ROOT}

# shellcheck source=bin/fm-brief-heading-lib.sh
. "$FM_ROOT/bin/fm-brief-heading-lib.sh" 2>/dev/null

ADMIN_NEGATION_RE="(^|[^[:alpha:]])(never|not|no|dont|don't|without|avoid|forbid|forbidden|refuse)([^[:alpha:]]|$)|n't([^[:alpha:]]|$)"

is_captain_authorized() {
  [ -n "${FM_TASK_ID:-}" ] || return 1
  fm_brief_task_heading_body "$FM_HOME/data/$FM_TASK_ID/brief.md" "## Captain's intent" 2>/dev/null \
    | grep -iE -- '--admin|admin merge' \
    | grep -viqE -- "$ADMIN_NEGATION_RE"
}

deny_refusal() {
  local reason="error: [hard-rule-2] worker cannot use --admin or bypass permissions; only captain explicit authorization confers merge authority."
  if [ "$IS_GH_WRAPPER" -eq 1 ]; then
    printf '%s\n' "$reason" >&2
    exit 2
  fi
  local escaped
  escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  if [ "$CURSOR_MODE" -eq 1 ]; then
    printf '{"permission":"deny","user_message":"%s"}\n' "$escaped"
    exit 0
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

if [ "$IS_GH_WRAPPER" -eq 1 ]; then
  has_pr=0
  has_merge=0
  has_admin=0
  for arg in "$@"; do
    case "$arg" in
      pr) has_pr=1 ;;
      merge) has_merge=1 ;;
      --admin|--admin=*) has_admin=1 ;;
    esac
  done
  if [ "$has_pr" -eq 1 ] && [ "$has_merge" -eq 1 ] && [ "$has_admin" -eq 1 ]; then
    is_captain_authorized || deny_refusal
  fi
  real_gh=$(find_real_gh) || {
    echo "error: gh executable not found on PATH" >&2
    exit 127
  }
  exec "$real_gh" "$@"
fi

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
      cat <<'EOF'
Usage: fm-admin-guard.sh [--command <cmd>] [--claude|--cursor]
       fm-admin-guard.sh gh <gh-args...>

Refuses `gh pr merge --admin` unless the task brief's `## Captain's intent` explicitly authorizes it.
Exits 0 to allow, 2 to deny (exit 0 with decision object for --cursor).
EOF
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

case "$CMD" in
  *--admin*) ;;
  *) exit 0 ;;
esac

is_admin_merge_command() {
  local cmd="$1"
  local normalized
  normalized=$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||;|\||&)/\n/g')
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$line" ] || continue
    local clean="${line//[\"\']/}"
    local words=()
    read -r -a words <<< "$clean"
    [ "${#words[@]}" -gt 0 ] || continue
    local idx=0
    while [ "$idx" -lt "${#words[@]}" ]; do
      local w="${words[$idx]}"
      case "$w" in
        *=*) ((idx++)) ;;
        sudo|env|exec|time|nohup) ((idx++)) ;;
        *) break ;;
      esac
    done
    [ "$idx" -lt "${#words[@]}" ] || continue
    local bin="${words[$idx]}"
    local bin_base="${bin##*/}"
    case "$bin_base" in
      gh|gh-axi) ;;
      *) continue ;;
    esac
    local has_pr=0 has_merge=0 has_admin=0
    for ((i=idx+1; i<${#words[@]}; i++)); do
      case "${words[$i]}" in
        pr) has_pr=1 ;;
        merge) has_merge=1 ;;
        --admin|--admin=*) has_admin=1 ;;
      esac
    done
    if [ "$has_pr" -eq 1 ] && [ "$has_merge" -eq 1 ] && [ "$has_admin" -eq 1 ]; then
      return 0
    fi
  done <<< "$normalized"
  return 1
}

if is_admin_merge_command "$CMD"; then
  is_captain_authorized || deny_refusal
fi

exit 0
