#!/usr/bin/env bash
set -eu
export EVIDENCE=/home/jon/.no-mistakes/evidence/01M331WRGZH34NEA90N07XDG81
focused_ci_tests() {
  test_crew_is_ci_waiting_classifier
  test_wedge_threshold_defers_to_a_ci_step
  test_ci_transition_at_shared_wedge_boundary
  test_ci_step_does_not_hide_a_gone_endpoint
  for scenario in ci-step-quiet ci-step-aged ci-step-control ci-transition-ordinary ci-transition-terminal ci-transition-busy ci-step-gone; do
    printf '\nScenario: %s\n' "$scenario"
    cat "$TMP_ROOT/$scenario/watch.out"
  done > "$EVIDENCE/watcher-transcript.txt"
}
export -f focused_ci_tests
FM_TEST_ONLY=focused_ci_tests bash tests/fm-watch-triage.test.sh
