#!/usr/bin/env bash
# Drives bin/fm-sos-intake.sh reconcile/status through the test harness fixture
# (real tasks-axi backlog, real fm-brief/fm-procevent-when; stub gh/curl/fm-spawn).
set -u
cd "$1"
sed -n "1,1326p" tests/fm-sos-intake.test.sh > tests/.demo-harness.sh; source tests/.demo-harness.sh; rm -f tests/.demo-harness.sh
parts=$(setup_case demo); home=${parts%%|*}; fd=${parts##*|}
step() { printf '\n$ %s\n' "$*"; }
step "fm-sos-intake.sh reconcile   # pass 1: bridge delivers SOS event id=1 for issue #$GH_ISSUE"
run_intake "$parts" reconcile 2>&1
step "fm-sos-intake.sh reconcile   # pass 2: same event replayed"
run_intake "$parts" reconcile 2>&1
step "rm state/fm-sos-intake.cursor; fm-sos-intake.sh reconcile   # pass 3: cursor lost, event replayed again"
rm -f "$home/state/fm-sos-intake.cursor"; run_intake "$parts" reconcile 2>&1
step "fm-sos-intake.sh status"
run_intake "$parts" status 2>&1
printf '\n--- side effects after 3 passes ---\n'
echo "task rows for SOS UUID: $(FM_HOME=$home "$TASKS_AXI" list 2>/dev/null | grep -c "$TASK_ID")"
echo "github comments posted: $(count_of '' "$fd/comments.log")"
echo "crewmates spawned:      $(count_of 'fm-spawn' "$fd/spawn.log")"; cat "$fd/spawn.log"
echo "close watches armed:    $(ls "$home/state/when/"*.spec | wc -l)"
echo "gh issue close attempts: $(count_of CLOSE-ATTEMPTED "$fd/gh.log")"
