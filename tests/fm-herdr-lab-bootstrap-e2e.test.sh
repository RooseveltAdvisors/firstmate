#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/fm-herdr-lab.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HELPER" ] || { echo "skip: Herdr lab helper not executable at $HELPER"; exit 0; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-lab-bootstrap-e2e.XXXXXX")
STATE_DIR="$TMP_ROOT/lab-state"
SESSION=
CLEANED=0
cleanup() {
  local status=$?
  if [ "$CLEANED" -eq 0 ] && [ -n "$SESSION" ]; then
    if FM_HERDR_LAB_STATE_DIR="$STATE_DIR" "$HELPER" teardown "$SESSION" >/dev/null 2>&1; then
      CLEANED=1
    else
      status=1
    fi
  fi
  if [ "$CLEANED" -eq 1 ] || [ -z "$SESSION" ]; then
    rm -rf "$TMP_ROOT"
  else
    printf 'not ok - guarded teardown refused; retaining cleanup evidence at %s\n' "$TMP_ROOT" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

SESSION=$(FM_HERDR_LAB_STATE_DIR="$STATE_DIR" "$HELPER" name fm-herdr-lab-bootstrap-real) \
  || fail 'could not generate an isolated Herdr lab session name'
export FM_HERDR_LAB_STATE_DIR="$STATE_DIR"
export HERDR_SESSION=default
"$HELPER" provision "$SESSION" || fail 'could not provision the isolated Herdr lab session'

OUT=$(HERDR_SESSION=default "$HELPER" bootstrap-pane "$SESSION") \
  || fail 'bootstrap-pane failed against the isolated real Herdr lab'
OUT_SESSION=$(printf '%s' "$OUT" | jq -r '.session // empty')
PANE=$(printf '%s' "$OUT" | jq -r '.pane_id // empty')
CLIENT_PID=$(printf '%s' "$OUT" | jq -r '.client_pid // empty')
[ "$OUT_SESSION" = "$SESSION" ] || fail "bootstrap-pane returned the wrong session: $OUT"
[ -n "$PANE" ] || fail "bootstrap-pane returned no pane identity: $OUT"
[[ "$CLIENT_PID" =~ ^[0-9]+$ ]] || fail "bootstrap-pane returned no client PID: $OUT"

PANE_INFO=$("$HELPER" run "$SESSION" pane get "$PANE") \
  || fail 'the authoritative bootstrap pane could not be read'
printf '%s' "$PANE_INFO" | jq -e --arg pane "$PANE" '.result.pane.pane_id == $pane' >/dev/null \
  || fail "the real Herdr pane identity did not round-trip: $PANE_INFO"
[ -f "$STATE_DIR/$SESSION.session-identity.json" ] \
  || fail 'bootstrap proof lost the helper-owned named-session identity'
pass 'real isolated named lab creates and identifies one helper-owned bootstrap pane'

"$HELPER" stop "$SESSION" >/dev/null || fail 'guarded stop did not clean the real bootstrap client'
"$HELPER" teardown "$SESSION" >/dev/null || fail 'guarded teardown did not remove the real named lab'
CLEANED=1
assert_absent() { [ ! -e "$1" ] || fail "$2"; }
assert_absent "$STATE_DIR/$SESSION.fleet-state.json" 'real teardown left the fleet-state tripwire'
pass 'real isolated named lab bootstrap cleanup preserves the default-session tripwire'
