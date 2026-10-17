#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh's --surface ui flag: a promoted UI ship
# gets the same live-image Definition of done and surface=ui task record that a
# bin/fm-brief.sh --surface ui ship spawn gets, and promotion without the flag
# records no surface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote)

promote_scout() {  # <home> <id> [promote args...]
  local home=$1 id=$2
  shift 2
  mkdir -p "$home/state" "$home/data/$id"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
  cat > "$home/data/$id/brief.md" <<'BRIEF'
# Task
## Captain's intent
Fix the signage banner.

## Firstmate spec
Match the approved mock.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
BRIEF
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" "$@" 2>&1
}

test_promote_with_surface_ui_marks_a_ui_ship() {
  local home id out status
  home="$TMP_ROOT/surface-ui-home"
  id=promote-ui
  out=$(promote_scout "$home" "$id" --mode no-mistakes --yolo off --surface ui)
  status=$?
  expect_code 0 "$status" "promotion with --surface ui should succeed"$'\n'"$out"
  assert_grep 'This is a UI ship: the task is not done until the done report names a live-origin image path' \
    "$home/data/$id/ship-instructions.md" "promoted UI ship instructions lack the live-image paragraph"
  assert_grep 'Delivery contract: mode=no-mistakes surface=ui' "$home/data/$id/ship-instructions.md" \
    "promoted UI ship contract line lacks surface=ui"
  assert_grep 'surface=ui' "$home/state/$id.meta" "promoted UI ship task record lacks surface=ui"
  assert_grep 'kind=ship' "$home/state/$id.meta" "promotion did not flip the task to a ship"
  pass "promotion with --surface ui renders the live-image DoD and records surface=ui"
}

test_promote_without_surface_records_no_surface() {
  local home id out status
  home="$TMP_ROOT/no-surface-home"
  id=promote-plain
  out=$(promote_scout "$home" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "promotion without --surface should succeed"$'\n'"$out"
  assert_no_grep 'This is a UI ship' "$home/data/$id/ship-instructions.md" \
    "promotion without --surface rendered the live-image paragraph"
  assert_no_grep 'surface=' "$home/state/$id.meta" "promotion without --surface recorded a surface"
  assert_grep 'kind=ship' "$home/state/$id.meta" "promotion did not flip the task to a ship"
  pass "promotion without --surface records no surface"
}

test_promote_refuses_an_unknown_surface() {
  local home id out status
  home="$TMP_ROOT/bad-surface-home"
  id=promote-bad
  out=$(promote_scout "$home" "$id" --mode no-mistakes --yolo off --surface=api)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion with --surface=api should be refused"
  assert_contains "$out" "--surface must be ui" "unknown surface refusal did not explain itself"
  assert_grep 'kind=scout' "$home/state/$id.meta" "a refused promotion changed the task record"
  pass "promotion refuses a surface other than ui"
}

test_promote_with_surface_ui_marks_a_ui_ship
test_promote_without_surface_records_no_surface
test_promote_refuses_an_unknown_surface

echo "all fm-promote tests passed"
