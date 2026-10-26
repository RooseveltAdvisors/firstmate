#!/usr/bin/env bash
# Bounded base/target comparison for the ack-stopped-cycle flake candidates.
set -u
EVID=/home/jon/.no-mistakes/evidence/01M5SDV9REPXRKVD9443H5KZTR
T=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M5SDV9REPXRKVD9443H5KZTR
B=/tmp/fm-r3/base-tree
CASES="test_turn_ended_malformed_prior_hash_surfaced test_separate_self_announced_answers_after_fold_wake_once test_unreadable_status_reports_once_per_file_state test_permission_recovery_surfaces_preserved_status test_stale_terminal_status_overridden_by_active_run test_nonterminal_stale_provably_working_absorbed_then_escalated test_nonterminal_stale_paused_absorbed_then_resurfaced"
REPS=10

run_tree() { # <dir> <log>
  local dir=$1 log=$2 pass=0 fail=0 c r out
  for r in $(seq 1 "$REPS"); do
    for c in $CASES; do
      out=$(cd "$dir" && env -u NO_MISTAKES_GATE FM_TEST_ONLY="$c" bash tests/fm-watch-triage.test.sh 2>&1)
      if printf '%s\n' "$out" | grep -q '^ok '; then
        pass=$((pass + 1)); printf 'ok rep=%s %s\n' "$r" "$c"
      else
        fail=$((fail + 1)); printf 'FAIL rep=%s %s\n%s\n' "$r" "$c" "$out" | tail -20
      fi
    done
  done
  printf 'TREE %s: case-runs pass=%s fail=%s (reps=%s x cases=%s)\n' "$dir" "$pass" "$fail" "$REPS" "$(printf '%s\n' $CASES | wc -l)"
}

{
  run_tree "$T" "$EVID/flake-ab-target-r3.log" 2>&1 | tee "$EVID/flake-ab-target-r3.log"
  run_tree "$B" "$EVID/flake-ab-base-r3.log" 2>&1 | tee "$EVID/flake-ab-base-r3.log"
} > "$EVID/flake-ab-r3-summary.log" 2>&1
echo done > "$EVID/flake-ab-r3.done"
