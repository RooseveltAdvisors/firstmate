#!/usr/bin/env bash
set -euo pipefail
ROOT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M0MGT1QRAZYV2RRHYNW6QXEC
EVIDENCE=/tmp/no-mistakes-evidence/01M0MGT1QRAZYV2RRHYNW6QXEC
CAPTURE=$EVIDENCE/capture-pane-env.sh
SESSION="fm-lab-env-isolation-$$-$RANDOM"

. "$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/bin/backends/herdr.sh"

cleanup() {
  fm_herdr_lab_teardown "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

chmod +x "$CAPTURE"
BEFORE=$(fm_herdr_lab_fleet_state "$SESSION")
echo "default-session-before=$BEFORE"
fm_herdr_lab_prepare "$SESSION"

# Simulate the contaminated long-lived Firstmate launcher from the bug report.
env FM_HOME=/tmp/wrong-home FM_ROOT_OVERRIDE=/tmp/wrong-root FM_STATE_OVERRIDE=/tmp/wrong-state \
  FM_DATA_OVERRIDE=/tmp/wrong-data FM_PROJECTS_OVERRIDE=/tmp/wrong-projects FM_CONFIG_OVERRIDE=/tmp/wrong-config \
  CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed \
  GROK_AGENT=1 FM_SUPERVISION_MODEL=autoarm FM_HERDR_SENTINEL=kept \
  bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$2"' _ "$ROOT" "$SESSION"

echo "isolated-server-running=$(fm_backend_herdr_cli "$SESSION" status --json | jq -r '.server.running')"
CREATE=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$EVIDENCE" --label env-isolation --no-focus)
WORKSPACE=$(printf '%s' "$CREATE" | jq -r '.result.workspace.workspace_id')
PANE1=$(printf '%s' "$CREATE" | jq -r '.result.root_pane.pane_id')
OUT1=$EVIDENCE/pane-env-first-launch.txt
fm_backend_herdr_cli "$SESSION" pane run "$PANE1" "$CAPTURE $OUT1" >/dev/null
for _ in $(seq 1 50); do [ -s "$OUT1" ] && break; sleep 0.1; done
[ -s "$OUT1" ]

echo "first-later-pane=$PANE1"
cat "$OUT1"

# Re-ensure the already-running named server from a differently polluted caller.
# A restart/environment replacement would make this new pane see 'changed'.
env FM_HOME=/tmp/other-home CURSOR_AGENT=other PI_CODING_AGENT=other FM_PI_HARNESS=other \
  FM_SUPERVISION_MODEL=other FM_HERDR_SENTINEL=changed \
  bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$2"' _ "$ROOT" "$SESSION"
TAB=$(fm_backend_herdr_cli "$SESSION" tab create --workspace "$WORKSPACE" --cwd "$EVIDENCE" --label after-reensure --no-focus)
PANE2=$(printf '%s' "$TAB" | jq -r '.result.root_pane.pane_id')
OUT2=$EVIDENCE/pane-env-after-reensure.txt
fm_backend_herdr_cli "$SESSION" pane run "$PANE2" "$CAPTURE $OUT2" >/dev/null
for _ in $(seq 1 50); do [ -s "$OUT2" ] && break; sleep 0.1; done
[ -s "$OUT2" ]

echo "later-pane-after-reensure=$PANE2"
cat "$OUT2"

for file in "$OUT1" "$OUT2"; do
  for name in FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_SUPERVISION_MODEL; do
    grep -Fx "$name=<unset>" "$file" >/dev/null
  done
  grep -Fx 'FM_HERDR_SENTINEL=kept' "$file" >/dev/null
  grep -Fx "HERDR_SESSION=$SESSION" "$file" >/dev/null
done

echo 'assertion=scrubbed launch-only variables; preserved unrelated sentinel and named-session routing'
echo 'assertion=already-running server retained original environment on re-ensure'

fm_herdr_lab_teardown "$SESSION"
trap - EXIT
AFTER=$(fm_herdr_lab_fleet_state "$SESSION")
echo "default-session-after=$AFTER"
[ "$BEFORE" = "$AFTER" ]
SESSIONS=$(fm_herdr_lab_session_list "$SESSION")
if printf '%s' "$SESSIONS" | jq -e --arg name "$SESSION" '.sessions[]? | select(.name == $name)' >/dev/null; then
  echo 'error=isolated session still exists after cleanup' >&2
  exit 1
fi
echo 'cleanup=isolated session removed; active default session unchanged'
