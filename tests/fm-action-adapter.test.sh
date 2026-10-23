#!/usr/bin/env bash
# Tool payloads other than the governed shell/read tools must refuse at the
# shell-hook adapter in every worker role (deny-by-default allowlist).
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-action-adapter-test)
GUARD="$ROOT/bin/fm-jev-guard.sh"
for key in tool_name toolName; do
  for tool in mcp__chrome_devtools__click mcp__chrome-devtools__evaluate_script mcp__browser__browser_click browser.click browser_fill mcp__chrome_devtools__future_effect \
    mcp__playwright__browser_click mcp__claude-in-chrome__navigate mcp__puppeteer__click agent_browser_click mcp__future_vendor__send WebFetch Agent; do
    payload=$(jq -nc --arg key "$key" --arg tool "$tool" '{($key):$tool,tool_input:{uid:"synthetic-send-button",command:"git status"},action_class:"mail_draft"}')
    for role in primary worker secondmate; do
      case "$role" in
        primary) root="$ROOT" ;;
        worker) root="$TMP/task"; mkdir -p "$root" ;;
        secondmate) root="$TMP/home"; mkdir -p "$root"; touch "$root/.fm-secondmate-home" ;;
      esac
      status=0
      output=$(printf '%s' "$payload" | FM_ROOT_OVERRIDE="$root" FM_HOME="$root" bash "$GUARD" 2>"$TMP/stderr") || status=$?
      [ "$status" -eq 2 ] || fail "$role unlisted tool transport allowed $tool ($key)"
      printf '%s' "$output" | jq -e '.decision=="deny"' >/dev/null || fail 'missing protocol deny'
      assert_contains "$(cat "$TMP/stderr")" "'$tool' has no approved action adapter" 'denial must name the refused tool'
      assert_contains "$(cat "$TMP/stderr")" 'mail_send is prohibited' 'denial must name mail policy'
    done
  done
done
payload='{"tool_name":"mcp__chrome_devtools__click","tool_input":{"uid":"synthetic-send-button"},"cursor_version":"synthetic"}'
status=0
output=$(printf '%s' "$payload" | bash "$GUARD" --claude 2>"$TMP/stderr") || status=$?
[ "$status" -eq 2 ] && [ -z "$output" ] || fail 'Claude browser refusal must use exit 2 and empty stdout'
jq -e '.hookSpecificOutput.permissionDecision=="deny"' "$TMP/stderr" >/dev/null || fail 'Claude deny protocol missing'
output=$(printf '%s' "$payload" | bash "$GUARD" --cursor 2>"$TMP/stderr") || fail 'Cursor denial protocol should exit 0'
printf '%s' "$output" | jq -e '.permission=="deny"' >/dev/null || fail 'Cursor decision must deny'

status=0
output=$(printf '%s' '{"tool_input":{"command":"git status"}}' | FM_ROOT_OVERRIDE="$TMP/task" bash "$GUARD" 2>"$TMP/stderr") || status=$?
[ "$status" -eq 2 ] || fail 'unnamed tool payload was allowed'
assert_contains "$(cat "$TMP/stderr")" "'unnamed' has no approved action adapter" 'unnamed denial must say so'

# Every governed shell/read transport shape (Claude/Codex, Cursor, Grok, Read)
# retains the existing non-primary behavior.
for payload in '{"tool_name":"Read","tool_input":{"file_path":"synthetic"}}' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
  '{"tool_name":"Shell","tool_input":{"command":"git status"},"cursor_version":"synthetic"}' '{"toolName":"run_terminal_command","toolInput":{"command":"git status"}}'; do
  output=$(printf '%s' "$payload" | FM_ROOT_OVERRIDE="$TMP/task" bash "$GUARD" 2>&1) || fail "governed tool was denied: $payload"
  [ -z "$output" ] || fail 'non-primary shell/read tool emitted a denial'
done
pass 'scenario6: unlisted hook transports deny before command and role fast paths; governed shell/read shapes allow'
