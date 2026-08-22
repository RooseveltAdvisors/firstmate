#!/usr/bin/env bash
set -euo pipefail
ROOT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M0MGT1QRAZYV2RRHYNW6QXEC/.no-mistakes-base-replay
EVIDENCE=/tmp/no-mistakes-evidence/01M0MGT1QRAZYV2RRHYNW6QXEC
CAPTURE=$EVIDENCE/capture-pane-env.sh
SESSION="fm-lab-base-replay-$$-$RANDOM"
. "$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/bin/backends/herdr.sh"
BEFORE=$(fm_herdr_lab_fleet_state "$SESSION")
cleanup() {
  fm_herdr_lab_teardown "$SESSION" >/dev/null 2>&1 || true
  AFTER=$(fm_herdr_lab_fleet_state "$SESSION" 2>/dev/null || true)
  echo "default-session-after=$AFTER"
  [ "$BEFORE" = "$AFTER" ] && echo 'cleanup=isolated base-replay session removed; active default session unchanged'
}
trap cleanup EXIT

echo "default-session-before=$BEFORE"
fm_herdr_lab_prepare "$SESSION"
env FM_HOME=/tmp/wrong-home FM_ROOT_OVERRIDE=/tmp/wrong-root FM_STATE_OVERRIDE=/tmp/wrong-state \
  FM_DATA_OVERRIDE=/tmp/wrong-data FM_PROJECTS_OVERRIDE=/tmp/wrong-projects FM_CONFIG_OVERRIDE=/tmp/wrong-config \
  CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed \
  GROK_AGENT=1 FM_SUPERVISION_MODEL=autoarm FM_HERDR_SENTINEL=kept \
  bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "$2"' _ "$ROOT" "$SESSION"
CREATE=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$EVIDENCE" --label base-env-replay --no-focus)
PANE=$(printf '%s' "$CREATE" | jq -r '.result.root_pane.pane_id')
OUT=$EVIDENCE/pane-env-base-before-fix.txt
fm_backend_herdr_cli "$SESSION" pane run "$PANE" "$CAPTURE $OUT" >/dev/null
for _ in $(seq 1 50); do [ -s "$OUT" ] && break; sleep 0.1; done
[ -s "$OUT" ]
cat "$OUT"
if grep -Fx 'FM_HOME=<unset>' "$OUT" >/dev/null && grep -Fx 'CURSOR_AGENT=<unset>' "$OUT" >/dev/null && grep -Fx 'FM_SUPERVISION_MODEL=<unset>' "$OUT" >/dev/null; then
  echo 'unexpected=base satisfied the fixed contract' >&2
  exit 2
fi
echo 'expected-fixed-contract=FAIL (base server leaked launcher home, harness markers, and supervision override into a later pane)'
exit 1
