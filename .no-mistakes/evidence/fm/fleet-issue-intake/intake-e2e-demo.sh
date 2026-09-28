#!/usr/bin/env bash
# intake-e2e-demo.sh - end-to-end demonstration of the fleet issue intake
# (branch fm/fleet-issue-intake) against the REAL bin/fm-issue-intake.sh,
# a REAL tasks-axi backlog (markdown backend), and REAL fm-brief.sh /
# fm-procevent-when.sh collaborators. Only GitHub (gh), the event bridge
# (curl), the classifier (jev) and crewmate spawn (fm-spawn) are stubs, so
# every reporter-facing effect lands in inspectable logs and state.
#
# It reuses the fixture helpers from tests/fm-issue-intake.test.sh by sourcing
# a stripped copy (the trailing test invocations removed), then runs a scripted
# operator session proving the intent:
#   * rename fm-sos-intake -> fm-issue-intake: FM_ISSUE_* env, fm-iss- rows,
#     legacy fm-sos- row resolution, adopted pre-rename state files
#   * the --due fix: a fresh reconcile really creates the row (task_created=1)
#   * the jev verdict gate before dispatch: supported_bug dispatches,
#     not_supported declines+closes (captain carve-outs), captain_review holds,
#     fail-open, ledger-idempotent, never decline an already-dispatched ticket
set -u

ROOT="/home/jon/.no-mistakes/worktrees/46339c0817e0/01M3K3F9B9AM7QN15KJPY9DRWJ"
EV="/home/jon/.no-mistakes/evidence/01M3K3F9B9AM7QN15KJPY9DRWJ"
TRANSCRIPT="$EV/intake-e2e-transcript.txt"

CHECKS=0
FAILS=0

say() { printf '%s\n' "$*"; }

section() {
  printf '\n==================================================================\n'
  printf '== %s\n' "$*"
  printf '==================================================================\n'
}

expect_contains() { # <haystack> <needle> <label>
  CHECKS=$((CHECKS + 1))
  case "$1" in
    *"$2"*) printf '  [PASS] %s\n' "$3" ;;
    *) FAILS=$((FAILS + 1)); printf '  [FAIL] %s\n         wanted substring: %s\n         got: %s\n' "$3" "$2" "$(printf '%s' "$1" | head -c 800)" ;;
  esac
}

expect_absent_file() { # <path> <label>
  CHECKS=$((CHECKS + 1))
  if [ -e "$1" ]; then FAILS=$((FAILS + 1)); printf '  [FAIL] %s (but %s exists)\n' "$2" "$1"
  else printf '  [PASS] %s\n' "$2"; fi
}

expect_present_file() { # <path> <label>
  CHECKS=$((CHECKS + 1))
  if [ -e "$1" ]; then printf '  [PASS] %s\n' "$2"
  else FAILS=$((FAILS + 1)); printf '  [FAIL] %s (missing %s)\n' "$2" "$1"; fi
}

expect_grep_file() { # <fixed-string> <file> <label>
  CHECKS=$((CHECKS + 1))
  if grep -qF -- "$1" "$2" 2>/dev/null; then printf '  [PASS] %s\n' "$3"
  else FAILS=$((FAILS + 1)); printf '  [FAIL] %s (%s has no %s)\n' "$3" "$2" "$1"; fi
}

count_of_file() { # <fixed-string> <file> -> count, 0 when file/count absent
  local n
  n=$(grep -cF -- "$1" "$2" 2>/dev/null) || true
  echo "${n:-0}"
}

# --- load the fixture helpers from the test file (test invocations stripped) -
LIBSRC=$(mktemp "${TMPDIR:-/tmp}/intake-demo-lib.XXXXXX")
sed -e 's|^\. ".*lib\.sh"$|. "'"$ROOT"'/tests/lib.sh"|' \
    -e '/^test_[a-z_]*$/d' \
    "$ROOT/tests/fm-issue-intake.test.sh" > "$LIBSRC"
# shellcheck disable=SC1090
. "$LIBSRC"
rm -f "$LIBSRC"

case_parts=""
fresh() { case_parts=$(setup_case "$1"); HOME_DIR=${case_parts%%|*}; FAKE=${case_parts##*|}; }

show_state() { # <label>
  local home="$1"
  printf -- '--- persisted state: %s\n' "$2"
  printf '  ledger (%s/state/fm-issue-intake.log):\n' "$home"
  sed 's/^/    /' "$home/state/fm-issue-intake.log" 2>/dev/null || echo "    (none)"
  printf '  cursor: %s\n' "$(cat "$home/state/fm-issue-intake.cursor" 2>/dev/null || echo '(none)')"
  printf '  gh comments posted (%s):\n' "$FAKE"
  if [ -f "$FAKE/comments.log" ]; then
    awk -F'\t' '{ printf "    #%s: %s\n", $1, substr($2, 1, 220) }' "$FAKE/comments.log"
  else
    echo "    (none)"
  fi
  printf '  gh close attempts: %s | label edits: %s\n' \
    "$(count_of_file 'CLOSE-ATTEMPTED' "$FAKE/gh.log")" \
    "$(count_of_file 'not-supported' "$FAKE/edit.log")"
  printf '  spawns: %s\n' "$( [ -f "$FAKE/spawn.log" ] && sed 's/^/    /' "$FAKE/spawn.log" || echo '(none)')"
  printf '  task rows:\n'
  FM_HOME="$home" "$TASKS_AXI" list 2>/dev/null | grep -E 'fm-(iss|sos)-' | sed 's/^/    /' | head -10
  local st
  st=$(FM_HOME="$home" "$TASKS_AXI" show "$TASK_ID" 2>/dev/null | sed -n 's/^  state: //p' | head -1)
  [ -n "$st" ] || st=$(FM_HOME="$home" "$TASKS_AXI" show "fm-sos-$SOS_UUID" 2>/dev/null | sed -n 's/^  state: //p' | head -1)
  printf '  task state of the ticket row: %s\n' "${st:-(not found)}"
  printf '  armed close watches: %s\n' \
    "$(ls "$home/state/when" 2>/dev/null | grep '\.spec$' | tr '\n' ' ' || echo '(none)')"
}

say "FLEET ISSUE INTAKE - end-to-end demonstration"
say "worktree: $ROOT"
say "date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "script:   bin/fm-issue-intake.sh $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo '(no git)')"

# =====================================================================
section "1. supported_bug: verdict gate dispatches a fresh ticket (row really created)"
fresh demo-dispatch
say "\$ fm-issue-intake.sh reconcile          # jev stub answers supported_bug"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "task_created=1" "the --due fix: a fresh reconcile creates the task row"
expect_contains "$out" "dispatched=1" "a supported_bug ticket dispatches"
expect_contains "$out" "cursor=0->1" "the bridge cursor advances"
expect_contains "$(cat "$FAKE/comments.log" 2>/dev/null)" "Issue intake" "reporter-facing dispatched comment posted"
expect_contains "$(cat "$FAKE/comments.log" 2>/dev/null)" "$TASK_ID" "the comment names the fm-iss- row id"
expect_contains "$(cat "$FAKE/spawn.log" 2>/dev/null)" "$TASK_ID" "one crewmate spawned on the fm-iss- row"
expect_present_file "$HOME_DIR/state/when/when-sos-$GH_ISSUE.spec" "close watch armed against the renamed script"
expect_grep_file "fm-issue-intake.sh" "$HOME_DIR/state/when/when-sos-$GH_ISSUE.spec" "watch spec names fm-issue-intake.sh (not the retired fm-sos-intake.sh)"
CHECKS=$((CHECKS + 1))
if grep -q 'fm-sos-intake.sh' "$HOME_DIR/state/when/when-sos-$GH_ISSUE.spec" 2>/dev/null; then
  FAILS=$((FAILS + 1)); echo "  [FAIL] watch spec still points at the retired script"
else
  echo "  [PASS] watch spec carries no retired fm-sos-intake.sh path"
fi
expect_absent_file "$FAKE/edit.log" "dispatch never labels the issue"
expect_contains "$(grep -c 'CLOSE-ATTEMPTED' "$FAKE/gh.log" 2>/dev/null)" "0" "dispatch never closes the issue"
show_state "$HOME_DIR" "after dispatch"

say
say "\$ fm-issue-intake.sh status"
run_intake "$case_parts" status 2>&1 | sed 's/^/  /'

# =====================================================================
section "2. replay: same event again (lost cursor) changes nothing"
say "\$ rm state/fm-issue-intake.cursor   # simulate a lost cursor, replay the event"
rm -f "$HOME_DIR/state/fm-issue-intake.cursor"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "task_created=0" "replay mints no second row"
expect_contains "$out" "dispatched=0" "replay never double-dispatches"
expect_contains "$(count_of_file 'Issue intake' "$FAKE/comments.log")" "1" "exactly one dispatched comment across replays"
expect_contains "$(count_of_file 'fm-spawn' "$FAKE/spawn.log")" "1" "exactly one spawn across replays"
expect_contains "$(count_of_file 'verdict key=' "$HOME_DIR/state/fm-issue-intake.log")" "1" "the verdict is decided once and ledgered"

# =====================================================================
section "3. rename: FM_ISSUE_* posture env reaches the spawn, status shows fm-iss- rows"
fresh demo-env
say "\$ FM_ISSUE_MODE=direct-PR FM_ISSUE_YOLO=off fm-issue-intake.sh reconcile"
out=$(FM_ISSUE_MODE=direct-PR FM_ISSUE_YOLO=off run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$(cat "$FAKE/spawn.log" 2>/dev/null)" "--mode direct-PR" "FM_ISSUE_MODE is the spawn's delivery contract"
expect_contains "$(cat "$FAKE/spawn.log" 2>/dev/null)" "--yolo off" "FM_ISSUE_YOLO reaches the spawn"

# =====================================================================
section "4. rename: pre-rename fm-sos-intake state files are adopted; legacy fm-sos- row stays authoritative"
fresh demo-rename
# Deploy scenario: the old script's cursor + ledger exist, and the ticket's
# row was minted before the fm-sos -> fm-iss rename.
printf '1\n' > "$HOME_DIR/state/fm-sos-intake.cursor"
printf 'dispatch key=%s issue=%s task=fm-sos-%s at=2025-01-01T00:00:00Z\n' "$SOS_UUID" "$GH_ISSUE" "$SOS_UUID" \
  > "$HOME_DIR/state/fm-sos-intake.log"
FM_HOME="$HOME_DIR" "$TASKS_AXI" add "fm-sos-$SOS_UUID" "legacy row minted before the rename" \
  --kind ship --repo portal --priority 1 >/dev/null || say "!! legacy row setup failed"
say "pre-rename state: $(ls "$HOME_DIR/state" | grep fm-sos-intake | tr '\n' ' ')"
say "\$ fm-issue-intake.sh reconcile   # first run of the renamed script"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "task_created=0" "the legacy fm-sos- row is reused, not duplicated"
expect_absent_file "$HOME_DIR/state/fm-sos-intake.cursor" "legacy cursor adopted (file renamed away)"
expect_absent_file "$HOME_DIR/state/fm-sos-intake.log" "legacy ledger adopted (file renamed away)"
expect_present_file "$HOME_DIR/state/fm-issue-intake.cursor" "cursor now lives under the new name"
expect_contains "$(cat "$HOME_DIR/state/fm-issue-intake.log" 2>/dev/null)" "dispatch key=$SOS_UUID issue=$GH_ISSUE task=fm-sos-$SOS_UUID at=2025-01-01" "the pre-rename ledger carried over verbatim"
expect_contains "$(cat "$FAKE/comments.log" 2>/dev/null)" "fm-sos-$SOS_UUID" "the dispatched comment names the pre-rename row"
expect_contains "$(count_of_file "fm-iss-$SOS_UUID" "$HOME_DIR/state/fm-issue-intake.log")" "0" "no fm-iss- row is minted for a ticket a fm-sos- row owns"
show_state "$HOME_DIR" "after rename adoption"

# =====================================================================
section "5. not_supported: declined, labeled, closed; replay never repeats it"
fresh demo-decline
printf 'not_supported\n' > "$FAKE/jev-verdict"
: > "$FAKE/allow-close"
say "\$ fm-issue-intake.sh reconcile          # jev stub answers not_supported"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "declined=1" "the decline lands"
expect_contains "$(cat "$FAKE/comments.log" 2>/dev/null)" "**Not supported**" "reporter gets the decline comment"
expect_contains "$(cat "$FAKE/edit.log" 2>/dev/null)" "not-supported" "the not-supported label is applied"
expect_contains "$(grep CLOSE-ATTEMPTED "$FAKE/gh.log" 2>/dev/null)" "CLOSE-ATTEMPTED" "the issue is closed (decline is the only close)"
expect_contains "$(FM_HOME="$HOME_DIR" "$TASKS_AXI" show "$TASK_ID" 2>/dev/null | sed -n 's/^  state: //p' | head -1)" "done" "the task row closes"
expect_absent_file "$FAKE/spawn.log" "a declined ticket never spawns"
expect_absent_file "$HOME_DIR/state/when/when-sos-$GH_ISSUE.spec" "a declined ticket arms no close watch"
: > "$FAKE/gh.log"
say
say "\$ fm-issue-intake.sh reconcile          # replay"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "declined=1" "the recorded decline still counts as handled"
expect_contains "$(count_of_file '**Not supported**' "$FAKE/comments.log")" "1" "exactly one decline comment ever"
expect_contains "$(count_of_file 'CLOSE-ATTEMPTED' "$FAKE/gh.log")" "0" "replay never closes again"
show_state "$HOME_DIR" "after decline + replay"

# =====================================================================
section "6. captain_review: held for the captain - no comment, no close, no spawn"
fresh demo-hold
printf 'captain_review\n' > "$FAKE/jev-verdict"
say "\$ fm-issue-intake.sh reconcile          # jev stub answers captain_review"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "review=1" "the hold is counted"
expect_contains "$out" "held for the captain" "the hold is visible to the operator"
expect_absent_file "$FAKE/comments.log" "a held ticket posts no comment"
expect_absent_file "$FAKE/spawn.log" "a held ticket never spawns"
expect_contains "$(grep -c CLOSE-ATTEMPTED "$FAKE/gh.log" 2>/dev/null)" "0" "a held ticket is never closed"
expect_contains "$(FM_HOME="$HOME_DIR" "$TASKS_AXI" show "$TASK_ID" 2>/dev/null | sed -n 's/^  state: //p' | head -1)" "queued" "the row stays queued for the captain"

# =====================================================================
section "7. fail-open: a broken classifier holds instead of deciding"
fresh demo-failopen
printf 'fail\n' > "$FAKE/jev-verdict"
: > "$FAKE/allow-close"
say "\$ fm-issue-intake.sh reconcile          # jev CLI exits 1 (outage)"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "review=1" "an unreachable classifier fails open to captain_review"
expect_contains "$(grep -c CLOSE-ATTEMPTED "$FAKE/gh.log" 2>/dev/null)" "0" "a broken classifier never closes"
expect_absent_file "$FAKE/spawn.log" "a broken classifier never dispatches"

# =====================================================================
section "8. never decline an already-dispatched ticket"
fresh demo-dispatched
say "\$ fm-issue-intake.sh reconcile --no-verdict   # ops run dispatches first"
out=$(run_intake "$case_parts" reconcile --no-verdict 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "dispatched=1" "the ops run dispatches with the gate off"
printf 'not_supported\n' > "$FAKE/jev-verdict"
: > "$FAKE/allow-close"
say
say "\$ fm-issue-intake.sh reconcile          # later gate-on pass: not_supported"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "already dispatched" "the review line says why it was held"
expect_contains "$out" "declined=0" "the in-flight ticket is never declined"
expect_contains "$(grep -c CLOSE-ATTEMPTED "$FAKE/gh.log" 2>/dev/null)" "0" "work in flight is never closed"
expect_contains "$(count_of_file '**Not supported**' "$FAKE/comments.log")" "0" "no decline comment on a dispatched ticket"
expect_contains "$(count_of_file 'not-supported' "$FAKE/edit.log")" "0" "no decline label on a dispatched ticket"
expect_contains "$(FM_HOME="$HOME_DIR" "$TASKS_AXI" show "$TASK_ID" 2>/dev/null | sed -n 's/^  state: //p' | head -1)" "queued" "the dispatched row stays open for the crewmate"
expect_contains "$(count_of_file 'fm-spawn' "$FAKE/spawn.log")" "1" "the hold spawns no second crewmate"

# =====================================================================
section "9. captain carve-out: a captain-closed ticket is never declined"
fresh demo-captain-closed
say "\$ fm-issue-intake.sh reconcile --no-dispatch --no-verdict   # staging pass arms the watch"
out=$(run_intake "$case_parts" reconcile --no-dispatch --no-verdict 2>&1) || say "!! staging rc=$?"
say "$out"
printf '{"state":"CLOSED"}\n' > "$FAKE/gh-state-$GH_ISSUE"
say "\$ fm-issue-intake.sh watch-fire $GH_ISSUE $SOS_UUID        # captain closes the issue"
out=$(run_intake "$case_parts" watch-fire "$GH_ISSUE" "$SOS_UUID" 2>&1) || say "!! watch-fire rc=$?"
say "$out"
printf 'not_supported\n' > "$FAKE/jev-verdict"
: > "$FAKE/allow-close"
say
say "\$ fm-issue-intake.sh reconcile          # gate-on pass: not_supported on the closed ticket"
out=$(run_intake "$case_parts" reconcile 2>&1) || say "!! reconcile rc=$?"
say "$out"
expect_contains "$out" "declined=0" "the captain-closed ticket is not declined"
expect_contains "$(count_of_file '**Not supported**' "$FAKE/comments.log")" "0" "no decline comment"
expect_contains "$(count_of_file 'not-supported' "$FAKE/edit.log")" "0" "no decline label"
expect_contains "$(grep -c CLOSE-ATTEMPTED "$FAKE/gh.log" 2>/dev/null)" "0" "the close is never retried by intake"
expect_contains "$(count_of_file 'Closed by the captain' "$FAKE/comments.log")" "1" "watch-fire announced the captain's close exactly once"

# =====================================================================
section "10. dry-run: plans, changes nothing"
fresh demo-dryrun
say "\$ fm-issue-intake.sh reconcile --dry-run"
out=$(run_intake "$case_parts" reconcile --dry-run 2>&1) || say "!! dry-run rc=$?"
say "$out"
expect_contains "$out" "would-create: task fm-iss-$SOS_UUID" "dry-run reports the row it would create"
expect_absent_file "$FAKE/comments.log" "dry-run posts no comment"
expect_absent_file "$FAKE/spawn.log" "dry-run spawns nothing"
expect_absent_file "$HOME_DIR/state/fm-issue-intake.cursor" "dry-run leaves the cursor untouched"

printf '\n==================================================================\n'
printf 'CHECKS: %s total, %s failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" -eq 0 ] && printf 'RESULT: PASS\n' || printf 'RESULT: FAIL\n'
exit "$([ "$FAILS" -eq 0 ] && echo 0 || echo 1)"
