#!/usr/bin/env bash
# intake-due-regression.sh - reproduce the reported --due failure ("every
# reconcile reported task_created=0") against the real tools, then show the
# fixed intake creating the row.
#
#   A. the mechanism: fm-tasks-axi rejects `add ... --due` (VALIDATION_ERROR),
#      and accepts the current add surface.
#   B. the pre-fix intake (rev 1861782d, bin/fm-sos-intake.sh - the revision
#      that introduced --due) run end to end in a fixture: reconcile reports
#      task_created=0 and creates no row.
#   C. the fixed intake (this branch's bin/fm-issue-intake.sh): the same
#      scenario reports task_created=1 and the row exists.
set -u

ROOT="/home/jon/.no-mistakes/worktrees/46339c0817e0/01M3K3F9B9AM7QN15KJPY9DRWJ"
EV="/home/jon/.no-mistakes/evidence/01M3K3F9B9AM7QN15KJPY9DRWJ"
TRANSCRIPT="$EV/intake-due-regression-transcript.txt"

CHECKS=0
FAILS=0
say() { printf '%s\n' "$*"; }
section() {
  printf '\n==================================================================\n'
  printf '== %s\n' "$*"
  printf '==================================================================\n'
}
expect_contains() {
  CHECKS=$((CHECKS + 1))
  case "$1" in
    *"$2"*) printf '  [PASS] %s\n' "$3" ;;
    *) FAILS=$((FAILS + 1)); printf '  [FAIL] %s\n         wanted substring: %s\n         got: %s\n' "$3" "$2" "$(printf '%s' "$1" | head -c 600)" ;;
  esac
}

# --- fixture helpers from the test file -------------------------------------
LIBSRC=$(mktemp "${TMPDIR:-/tmp}/intake-due-lib.XXXXXX")
sed -e 's|^\. ".*lib\.sh"$|. "'"$ROOT"'/tests/lib.sh"|' \
    -e '/^test_[a-z_]*$/d' \
    "$ROOT/tests/fm-issue-intake.test.sh" > "$LIBSRC"
# shellcheck disable=SC1090
. "$LIBSRC"
rm -f "$LIBSRC"

fresh() { parts=$(setup_case "$1"); home=${parts%%|*}; fb=$(printf '%s' "$parts" | cut -d'|' -f2); fd=${parts##*|}; }

say "FM-SOS/ISSUE INTAKE - the --due regression, reproduced end to end"
say "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# =====================================================================
section "A. mechanism: tasks-axi has no add --due flag"
h=$(mktemp -d "${TMPDIR:-/tmp}/due-mech.XXXXXX")
cp "$ROOT/.tasks.toml" "$h/"
mkdir -p "$h/data" "$h/state"
say "\$ fm-tasks-axi.sh add fm-iss-demo 'due demo' --kind ship --repo portal --priority 1 --due +2w --body x --json"
FM_HOME="$h" "$TASKS_AXI" add fm-iss-due-demo "due demo" --kind ship --repo portal \
  --priority 1 --due +2w --body x --json 2>&1; rc=$?
say "rc=$rc"
expect_contains "$(FM_HOME="$h" "$TASKS_AXI" add fm-iss-due-demo2 "due demo" --kind ship --repo portal --priority 1 --due +2w --body x --json 2>&1)" \
  "VALIDATION_ERROR" "the synthetic --due flag is rejected before any write"
[ "$rc" -ne 0 ] && say "  (non-zero rc: task_ensure would fail => task_created=0)"
say
say "\$ fm-tasks-axi.sh add fm-iss-demo 'no due' --kind ship --repo portal --priority 1 --why '...' --body x --json"
out=$(FM_HOME="$h" "$TASKS_AXI" add fm-iss-nodue-demo "no due" --kind ship --repo portal \
  --priority 1 --why "staff SOS report awaiting fix" --body x --json 2>&1) || say "!! rc=$?"
say "$out"
expect_contains "$out" '"ok": true' "the current add surface succeeds (row written)"
rm -rf "$h"

# =====================================================================
section "B. pre-fix intake (rev 1861782d fm-sos-intake.sh): reconcile reports task_created=0"
old=$(mktemp "${TMPDIR:-/tmp}/fm-sos-intake-1861782d.XXXXXX")
git -C "$ROOT" show 1861782d:bin/fm-sos-intake.sh > "$old" || { echo "could not extract old script"; exit 1; }
chmod +x "$old"
say "extracted $(git -C "$ROOT" log --oneline -1 1861782d)"
fresh due-old
say "\$ fm-sos-intake.sh reconcile   # FM_SOS_* env, same stubs, real tasks-axi"
out=$(FM_HOME="$home" \
  FM_SOS_BRIDGE_URL="http://bridge.invalid:8791" \
  FM_SOS_TASKS="$TASKS_AXI" \
  FM_SOS_SPAWN="$fb/fm-spawn" \
  FM_SOS_BRIEF="$ROOT/bin/fm-brief.sh" \
  FM_SOS_WHEN="$ROOT/bin/fm-procevent-when.sh" \
  FM_ISSUE_FAKE_DIR="$fd" \
  PATH="$fb:$PATH" \
  "$old" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "task_created=0" "the pre-fix intake reports task_created=0"
FM_HOME="$home" "$TASKS_AXI" show "fm-iss-$SOS_UUID" >/dev/null 2>&1
st=$?
if [ "$st" -ne 0 ]; then
  CHECKS=$((CHECKS + 1)); say "  [PASS] no task row was created by the pre-fix intake"
else
  CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); say "  [FAIL] a row exists despite task_created=0"
fi
rm -f "$old"

# =====================================================================
section "C. fixed intake (bin/fm-issue-intake.sh): reconcile reports task_created=1"
fresh due-new
say "\$ fm-issue-intake.sh reconcile   # same scenario, FM_ISSUE_* env"
out=$(run_intake "$parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "task_created=1" "the fixed intake creates the row"
expect_contains "$(FM_HOME="$home" "$TASKS_AXI" show "fm-iss-$SOS_UUID" 2>&1 | sed -n 's/^  state: //p' | head -1)" \
  "queued" "the row exists in the backlog"

printf '\n==================================================================\n'
printf 'CHECKS: %s total, %s failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" -eq 0 ] && printf 'RESULT: PASS\n' || printf 'RESULT: FAIL\n'
exit "$([ "$FAILS" -eq 0 ] && echo 0 || echo 1)"
