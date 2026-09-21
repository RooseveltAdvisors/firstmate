#!/usr/bin/env bash
set -eu
reproduce_ci_step() {
  local dir state fakebin out capture verdict
  dir=$(wedge_threshold_fixture actual-ci-verdict 'working: implementation committed' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  verdict=$(cat /home/jon/.no-mistakes/evidence/01M331WRGZH34NEA90N07XDG81/crew-state-transcript.txt)
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" test:fm-wedge "$verdict" exit || fail 'watcher did not emit a wake'
  cat "$out" > /home/jon/.no-mistakes/evidence/01M331WRGZH34NEA90N07XDG81/actual-ci-step-wake.txt
  cat "$out"
  [ ! -e "$state/.wedge-escalations-test_fm-wedge" ] || fail 'running CI step from real crew-state classifier still wedge-escalates'
}
export -f reproduce_ci_step
FM_TEST_ONLY=reproduce_ci_step bash tests/fm-watch-triage.test.sh
