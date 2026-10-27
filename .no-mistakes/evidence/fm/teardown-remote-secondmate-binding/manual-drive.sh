#!/usr/bin/env bash
# Manual end-user drive of the real bin/fm-teardown.sh for the fm-1777z
# scenarios. Builds the incident's exact state (a secondmate whose registry
# record is a remote route while its live home sits locally) in disposable
# fixture homes, then drives the two operator flows an end user runs:
#   1. lane teardown of a finished lane owned by that secondmate
#   2. retirement of the secondmate itself
# Usage: manual-drive.sh <worktree> <pre-fix-bin-dir> <mode: post|pre>
set -u
WORKTREE=$1
PRE_BIN=$2
MODE=$3

fm_manual_drive() {
  TEARDOWN="$ROOT/bin/fm-teardown.sh"
  PRE_TEARDOWN="$PRE_BIN/fm-teardown.sh"
  case "$MODE" in
    post) drive_teardown="$TEARDOWN" ;;
    pre)  drive_teardown="$PRE_TEARDOWN" ;;
    *) echo "bad mode $MODE" >&2; return 1 ;;
  esac

  echo "########## mode=$MODE product=$drive_teardown ##########"

  echo
  echo "=== SCENARIO A: lane teardown of a remote-registered, locally seated secondmate ==="
  local parent child out rc
  parent=$(make_home "manual-lane-$MODE-parent")
  child=$(make_home "manual-lane-$MODE-child")
  printf '%s\n' remote-mate > "$child/.fm-secondmate-home"
  printf -- '- remote-mate - synthetic (host: agt-test; root: /opt/ra/firstmate; home: /remote/home/remote-mate; scope: synthetic; projects: ; added 2026-07-30)\n' \
    > "$parent/data/secondmates.md"
  seed_commitment "$parent" pf-manual-"$MODE" req-manual-"$MODE" x secondmate:remote-mate work-manual-"$MODE"
  fm_write_meta "$parent/state/remote-mate.meta" "kind=secondmate" "home=$child"
  fm_write_meta "$child/state/work-manual-$MODE.meta" \
    "window=firstmate:fm-work-manual-$MODE" "endpoint_task_id=work-manual-$MODE" \
    "worktree=$child" "project=$child" "kind=ship" "mode=local-only" "spawn_gen=manual-fixture"
  echo "--- operator command: FM_HOME=$child bin/fm-teardown.sh work-manual-$MODE ---"
  rc=0
  out=$(PATH="$child/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$child" \
    FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$parent" \
    "$drive_teardown" work-manual-"$MODE" 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "--- exit code: $rc ---"
  echo "--- child work metadata afterwards: ---"
  ls "$child/state" | sed 's/^/    /'
  case "$out" in
    *"cannot resolve the primary home"*) echo "OBSERVED: incident refusal 'cannot resolve the primary home'" ;;
    *"registered on the remote route agt-test:/remote/home/remote-mate"*) echo "OBSERVED: route-form acceptance warning naming the recorded route" ;;
    *) echo "OBSERVED: neither the incident refusal nor the route warning" ;;
  esac

  echo
  echo "=== SCENARIO B: retirement of the secondmate itself (the removal-identity guard) ==="
  local p2 c2 fakebin log
  p2=$(make_home "manual-retire-$MODE-parent" relay-off)
  c2=$(make_home "manual-retire-$MODE-child" relay-off)
  mark_firstmate_home "$c2"
  printf '%s\n' remote-mate > "$c2/.fm-secondmate-home"
  printf -- '- remote-mate - synthetic (host: agt-test; root: /opt/ra/firstmate; home: /remote/home/remote-mate; scope: synthetic; projects: ; added 2026-07-30)\n' \
    > "$p2/data/secondmates.md"
  fm_write_secondmate_meta "$p2/state/remote-mate.meta" "$c2"
  fakebin=$(make_fake_tmux "$TMP_ROOT/manual-retire-$MODE-fake")
  log="$TMP_ROOT/manual-retire-$MODE-fake/tmux.log"
  echo "--- operator command: FM_HOME=$p2 bin/fm-teardown.sh remote-mate --retire-secondmate remote-mate ---"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$p2" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/manual-retire-$MODE-fake/pane.txt" \
    FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/manual-retire-$MODE-claims" \
    "$drive_teardown" remote-mate --retire-secondmate remote-mate 2>&1) || rc=$?
  printf '%s\n' "$out"
  echo "--- exit code: $rc ---"
  echo "--- afterwards: child home present? meta present? registry entry present? ---"
  [ -e "$c2" ] && echo "    child home: PRESENT" || echo "    child home: REMOVED"
  [ -e "$p2/state/remote-mate.meta" ] && echo "    parent meta: PRESENT" || echo "    parent meta: REMOVED"
  if grep -q '^- remote-mate ' "$p2/data/secondmates.md" 2>/dev/null; then
    echo "    registry entry: PRESENT"
  else
    echo "    registry entry: REMOVED"
  fi
  case "$out" in
    *"is registered at /remote/home/remote-mate, not "*) echo "OBSERVED: incident refusal 'is registered at <route>, not <local home>'" ;;
    *"registered on the remote route agt-test:/remote/home/remote-mate"*) echo "OBSERVED: route-form acceptance warning naming the recorded route" ;;
    *) echo "OBSERVED: neither the incident refusal nor the route warning" ;;
  esac
}

export -f fm_manual_drive
export WORKTREE PRE_BIN MODE
cd "$WORKTREE" || exit 1
FM_TEST_ONLY=fm_manual_drive bash tests/fm-public-followup.test.sh
