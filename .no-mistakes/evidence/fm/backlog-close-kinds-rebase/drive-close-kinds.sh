#!/usr/bin/env bash
# Live drive of the PR's changed product surfaces against a disposable home:
#   1. bin/fm-captain-hold.sh hold/answer end-to-end -> row done, answered note recorded
#   2. fm_backlog_done guarded close (the interface every caller uses):
#      six done-class reasons accepted; junk refused with row untouched;
#      project-work worker-record guard; captain-word override recorded;
#      Gerrit --pr landed reason rewritten to the row note
#   3. staged pending-close records: real writer (fm_backlog_close_marker_stage)
#      -> real reader (fm_backlog_close_marker_validate); staged mode must reject
#      superseded/cancelled notes decode would rewrite
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# This script lives in the evidence dir; ROOT is the run worktree.
ROOT=${FM_DRIVE_ROOT:-$PWD}

umask 022
unset TASKS_AXI_FILE TASKS_AXI_BACKEND NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS \
      FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE \
      FM_ROOT_OVERRIDE FM_HOME || :

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-closekind.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data" "$LAB/projects"
touch "$LAB/state/.last-watcher-beat"
printf 'claude\n' > "$LAB/config/crew-harness"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"

export FM_HOME="$LAB"
BL="$LAB/data/backlog.md"
FAILED=0

note() { printf '\n=== %s\n' "$*"; }
ok()   { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; FAILED=1; }

axi() { tasks-axi "$@" --file "$BL"; }
row_state() { axi show "$1" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
row_show() { axi show "$1" 2>/dev/null; }

# --- 1. captain-hold hold -> answer end-to-end ------------------------------
note "1. captain-hold: hold then answer a plain backlog task"
axi add hold-demo "ship the demo" --kind ship >/dev/null &&
  ok "added hold-demo" || bad "tasks-axi add failed"

"$ROOT/bin/fm-captain-hold.sh" hold hold-demo --reason "Which path? (A or B)" >/dev/null 2>&1 \
  && ok "hold placed" || bad "hold failed"
printf 'held=%s\n' "$(row_show hold-demo | sed -n 's/^  held: *//p' | head -1)"

# adversarial: empty decision file must be refused, task stays held
: > "$LAB/empty-decision.txt"
rc=0; out=$("$ROOT/bin/fm-captain-hold.sh" answer hold-demo --decision-file "$LAB/empty-decision.txt" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && [ "$(row_state hold-demo)" != "done" ]; then
  ok "empty decision refused (rc=$rc): $(printf '%s' "$out" | head -1)"
else
  bad "empty decision accepted (rc=$rc)"
fi

printf 'Ship it as planned.\nsecond line of the decision\n' > "$LAB/decision.txt"
rc=0; out=$("$ROOT/bin/fm-captain-hold.sh" answer hold-demo --decision-file "$LAB/decision.txt" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then ok "answer closed the task"; else bad "answer failed rc=$rc: $out"; fi
st=$(row_state hold-demo)
[ "$st" = done ] && ok "row state is done" || bad "row state is '$st', expected done"
row_show hold-demo > "$LAB/hold-demo-show.txt"
if grep -q 'answered: Ship it as planned.' "$LAB/hold-demo-show.txt"; then
  ok "closed row records the answered: reason"
else
  bad "answered reason not recorded on the row"; cat "$LAB/hold-demo-show.txt"
fi

# exact retry of the same decision is an idempotent replay (documented contract)
rc=0; "$ROOT/bin/fm-captain-hold.sh" answer hold-demo --decision-file "$LAB/decision.txt" >/dev/null 2>&1 || rc=$?
printf 'exact retry rc=%s\n' "$rc"
[ "$rc" -eq 0 ] && [ "$(row_state hold-demo)" = done ] \
  && ok "exact retry of the answered close is idempotent" \
  || bad "exact retry disturbed the closed row (rc=$rc state=$(row_state hold-demo))"
# adversarial: a CHANGED decision on the closed task must be rejected
printf 'Actually do something else entirely.\n' > "$LAB/decision2.txt"
rc=0; "$ROOT/bin/fm-captain-hold.sh" answer hold-demo --decision-file "$LAB/decision2.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ "$(row_state hold-demo)" = done ] \
  && ok "changed decision after the close refused, row stays done" \
  || bad "changed decision accepted (rc=$rc state=$(row_state hold-demo))"

# --- 2. guarded close through the library interface --------------------------
note "2. fm_backlog_done: done-class reasons accepted, junk refused"
close() {  # <id> <arg>...
  ( set -u
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    fm_backlog_done "$LAB/data" "$1" "$LAB/state" "${@:2}" && exit 0
    printf '%s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1 )
}

# six accepted reasons, each on its own fresh in-flight row
accept_case() { # <id> <arg...>
  axi add "$1" "work for $1" --kind ship >/dev/null
  axi start "$1" >/dev/null
  if out=$(close "$1" "${@:2}" 2>&1); then
    [ "$(row_state "$1")" = done ] && ok "reason accepted, row done: ${*:2}" \
      || bad "close returned 0 but row is $(row_state "$1"): ${*:2}"
  else
    bad "valid reason refused: ${*:2} -> $out"
  fi
}
accept_case c-pr   --pr https://github.com/o/r/pull/42
accept_case c-local --note 'local main'
accept_case c-report --report data/c-report/report.md
accept_case c-super --note 'superseded by c-pr'
accept_case c-canc  --note 'cancelled: the captain called it off'
accept_case c-ans   --note 'answered: the captain said ship it'

# recorded, not merely accepted
if row_show c-canc | grep -q 'cancelled: the captain called it off'; then
  ok "captain word persisted in the backlog"
else
  bad "captain word missing from backlog"
fi

note "2b. junk reasons refused with the row untouched"
axi add junk-c6 "work" --kind ship >/dev/null; axi start junk-c6 >/dev/null
for reason in 'Closed' 'done' '' 'superseded by ' 'cancelled: ' 'answered: ' 'local main and more'; do
  rc=0; out=$(close junk-c6 --note "$reason" 2>&1) || rc=$?
  st=$(row_state junk-c6)
  if [ "$rc" -ne 0 ] && [ "$st" = in_flight ]; then
    ok "refused, row untouched: --note '$reason'"
  else
    bad "accepted or mutated row: --note '$reason' (rc=$rc state=$st)"
  fi
done
rc=0; close junk-c6 --keep 5 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ "$(row_state junk-c6)" = in_flight ] \
  && ok "non-reason flag --keep refused" || bad "--keep accepted (rc=$rc)"
# refusal message names the rule
out=$(close junk-c6 --note 'Closed' 2>&1) || :
case "$out" in
  *'done-class reason'*'superseded by'*) ok "refusal names the rule and accepted reasons" ;;
  *) bad "refusal message unhelpful: $out" ;;
esac
# the row can still be closed afterwards
close junk-c6 --note 'local main' >/dev/null 2>&1 \
  && [ "$(row_state junk-c6)" = done ] \
  && ok "row still closable after refusals" || bad "row not closable after refusals"

note "2c. project-work worker-record guard (adversarial)"
proj() { axi add "$1" "project work" --kind "$2" --repo firstmate >/dev/null; axi start "$1" >/dev/null; }
proj p-ship ship; proj p-scout scout; proj p-worked ship
rc=0; out=$(close p-ship --note 'local main' 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && [ "$(row_state p-ship)" = in_flight ] && case "$out" in *'no worker record'*) true ;; *) false ;; esac; then
  ok "project ship with no worker record refused, naming the gap"
else
  bad "unworked project ship closed (rc=$rc): $out"
fi
rc=0; close p-scout --report data/p-scout/report.md >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ "$(row_state p-scout)" = in_flight ] \
  && ok "unworked scout refused against a report" || bad "unworked scout closed (rc=$rc)"
# captain word is the one override
rc=0; out=$(close p-ship --note 'cancelled: stood down before anyone picked it up' 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ "$(row_state p-ship)" = done ] \
   && row_show p-ship | grep -q 'stood down before anyone picked it up'; then
  ok "captain word overrides the guard and is recorded on the row"
else
  bad "captain word override failed (rc=$rc): $out"
fi
# blank captain words are not authority
axi add p-blank "project" --kind ship --repo firstmate >/dev/null; axi start p-blank >/dev/null
rc=0; close p-blank --note 'cancelled: ' >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ "$(row_state p-blank)" = in_flight ] \
  && ok "blank captain word refused" || bad "blank captain word accepted (rc=$rc)"
# a live task record is a worker record
: > "$LAB/state/p-worked.meta"
close p-worked --note 'local main' >/dev/null 2>&1 && [ "$(row_state p-worked)" = done ] \
  && ok "project work with a live worker record closes" || bad "worked project close refused"

note "2d. Gerrit change URL lands as the row note"
axi add gerrit-c "gerrit work" --kind ship >/dev/null; axi start gerrit-c >/dev/null
if out=$(close gerrit-c --pr 'https://gerrit.example.com/c/o/r/+/42' 2>&1) \
   && [ "$(row_state gerrit-c)" = done ] \
   && row_show gerrit-c | grep -q 'Gerrit change https://gerrit.example.com/c/o/r/+/42'; then
  ok "Gerrit --pr reason accepted and recorded as a note"
else
  bad "Gerrit close failed: $out"
fi

# --- 3. staged pending-close records: real writer -> real reader -------------
note "3. staged marker: writer then validator"
stage_and_validate() {  # <label> <expect: ok|reject> [flag...]
  local label=$1 expect=$2 rc=0 out
  shift 2
  ( set -u
    . "$ROOT/bin/fm-tasks-axi-lib.sh"
    . "$ROOT/bin/fm-backlog-transition-lib.sh"
    id="stage-$RANDOM"
    tmp="$LAB/state/.${id}.backlog-close.tmp"
    fm_backlog_close_marker_stage "$tmp" "$id" "$LAB/data" gen1 "$LAB/state" 0 "$@" || exit 2
    fm_backlog_close_marker_validate "$tmp" "$LAB/data" "$id" "$LAB/state" || exit 3
    [ "$FM_BACKLOG_CLOSE_VALIDATED_MODE" = close ] || exit 4
    exit 0 ) || rc=$?
  case "$expect:$rc" in
    ok:0) ok "$label: staged record accepted by the validator" ;;
    ok:*) bad "$label: expected acceptance, got rc=$rc" ;;
    reject:0) bad "$label: validator ACCEPTED a record it must reject" ;;
    reject:*) ok "$label: rejected (rc=$rc)" ;;
    *) bad "$label: unexpected rc=$rc" ;;
  esac
}
stage_and_validate "staged --note local%20main" ok --note 'local%20main'
stage_and_validate "staged --pr landing URL"    ok --pr 'https://github.com/o/r/pull/42'
stage_and_validate "staged --report"            ok --report 'data/scout/report.md'
stage_and_validate "staged zero args"           ok
stage_and_validate "staged superseded note (decode would rewrite it)" reject --note 'superseded by other'
stage_and_validate "staged cancelled note (decode would rewrite it)"  reject --note 'cancelled: word'
stage_and_validate "staged raw 'local main' via real writer (encoded on write)" ok --note 'local main'
# a hand-written marker with the raw spelling is not what the writer produces
rc=0
( set -u
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  id=stage-raw
  printf 'id=%s\ndata=%s\nspawn_gen=g1\ncleanup_incomplete=0\narg=--note\narg=local main\n' \
    "$id" "$LAB/data" > "$LAB/state/.${id}.backlog-close.tmp"
  fm_backlog_close_marker_validate "$LAB/state/.${id}.backlog-close.tmp" \
    "$LAB/data" "$id" "$LAB/state" ) || rc=$?
[ "$rc" -ne 0 ] && ok "hand-written raw-spelling marker rejected (rc=$rc)" \
  || bad "hand-written raw-spelling marker accepted by the validator"

printf '\nRESULT: %s\n' "$([ "$FAILED" -eq 0 ] && echo ALL-PASS || echo FAILURES)"
exit "$FAILED"
