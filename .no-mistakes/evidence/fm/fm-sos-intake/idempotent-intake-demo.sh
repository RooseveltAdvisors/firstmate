#!/usr/bin/env bash
# Drives the real bin/fm-sos-intake.sh with the test suite's stub gh/curl/fm-spawn
# fixtures to show one SOS event → one row, one comment, one watch, one crewmate,
# across a replayed event and a lost cursor.
set -u
WT=$1
sed -n '1,/^test_reconcile_creates_one_task_comment_watch_and_dispatch$/p' "$WT/tests/fm-sos-intake.test.sh" | sed "\$d" | sed "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh|$WT/tests/lib.sh|" > /tmp/fm-sos-demo-lib.sh
cd "$WT/tests"; . /tmp/fm-sos-demo-lib.sh
parts=$(setup_case demo); home=${parts%%|*}; fd=${parts##*|}
step() { echo; echo "\$ $*"; }
step "reconcile   # pass 1: bridge delivers SOS event id=1 for issue #$GH_ISSUE"
run_intake "$parts" reconcile 2>&1
step "reconcile   # pass 2: bridge drained, issue still open"
set_bridge_empty "$fd"; run_intake "$parts" reconcile 2>&1
step "rm state/fm-sos-intake.cursor; reconcile   # pass 3: cursor lost, same event replayed"
rm -f "$home/state/fm-sos-intake.cursor"; set_bridge_events "$fd" 1 "$SOS_UUID" "$GH_ISSUE"
run_intake "$parts" reconcile 2>&1
step "status"
run_intake "$parts" status 2>&1
echo; echo "=== side effects after 3 passes ==="
echo "task rows ($TASK_ID): $(FM_HOME="$home" "$TASKS_AXI" list 2>/dev/null | grep -c "$TASK_ID")"
echo "reporter comments posted: $(count_of 'SOS dispatch' "$fd/comments.log")"; cat "$fd/comments.log" | cut -c1-160
echo "crewmates spawned: $(count_of 'fm-spawn' "$fd/spawn.log")"; cat "$fd/spawn.log"
echo "gh issue close attempts: $(count_of CLOSE-ATTEMPTED "$fd/gh.log")"
echo; echo "=== ungranted home (no config/sos-autodispatch) ==="
p2=$(setup_case nogrant); rm -f "${p2%%|*}/config/sos-autodispatch"
run_intake "$p2" reconcile 2>&1; echo "rc=$?"
echo "crewmates spawned: $(count_of 'fm-spawn' "${p2##*|}/spawn.log")"
rm -rf "$TMP_ROOT" /tmp/fm-sos-demo-lib.sh
