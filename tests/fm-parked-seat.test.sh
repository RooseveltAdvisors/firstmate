#!/usr/bin/env bash
# tests/fm-parked-seat.test.sh - verify parked-seat record and watcher probe suppression.
#
# Tests the supported parked-seat lifecycle:
#   1. Verb allowlist: park and unpark are allowlisted control-plane verbs.
#   2. Probe suppression: fm_backend_target_of_meta suppresses parked targets by default,
#      omitting them from watcher probing without removing the endpoint record.
#   3. Probe resolution override: fm_backend_target_of_meta --include-parked preserves target
#      resolution for snapshots, selector resolution, and teardown.
#   4. Crew state: fm-crew-state reports state: parked · source: none for parked tasks.
#   5. Control plane verbs: fm-control park exits any running agent, sets parked=1 and note,
#      clears stale markers, and unpark clears the parked record.
#   6. Teardown safety: fm-teardown unlanded-work refusal stays 100% authoritative and
#      parking preserves unlanded commits.
#   7. Watcher probe loop: recorded_windows in fm-watch omits parked windows, producing
#      zero stale wakes across watcher cycles while work stays intact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

CONTROL="$ROOT/bin/fm-control.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-parked-seat)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT
fm_git_identity fmtest fmtest@example.invalid

# --- fake tmux stub ---------------------------------------------------------
make_tmux_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D="$FM_FAKE_DIR"
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      if [ "$payload" = /exit ] || [ "$payload" = /quit ]; then
        printf 'zsh' > "$D/command"
      fi
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -f "$D/pane" ]; then cat "$D/pane"; else printf '╭────╮\n│    │\n╰────╯\n'; fi
    exit 0 ;;
  list-windows)
    if [ -f "$D/windows" ]; then cat "$D/windows"; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

new_case() {  # <name>
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  make_tmux_stub "$dir" >/dev/null
  printf '%s\n' "$dir"
}

setup_task() {  # <case-dir> <id> <harness>
  local dir=$1 id=$2 harness=$3
  local home="$dir/home" proj="$dir/proj-$id" wt="$dir/wt-$id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

# --- 1. verb allowlist ------------------------------------------------------
test_control_verbs_allowlist() {
  local verbs
  verbs=$(fm_control_verbs)
  printf '%s\n' "$verbs" | grep -qx "park" || fail "park should be in fm_control_verbs"
  printf '%s\n' "$verbs" | grep -qx "unpark" || fail "unpark should be in fm_control_verbs"
  fm_control_verb_allowed park || fail "park should be allowed"
  fm_control_verb_allowed unpark || fail "unpark should be allowed"
  pass "control plane: park and unpark verbs are allowlisted"
}

# --- 2. probe suppression in fm_backend_target_of_meta ----------------------
test_backend_target_of_meta_probe_suppression() {
  local dir meta target
  dir="$TMP_ROOT/target-test-$RANDOM"
  mkdir -p "$dir"
  meta="$dir/task.meta"

  # Normal unparked task
  cat > "$meta" <<'EOF'
window=fmses:fm-100
backend=tmux
kind=ship
EOF
  target=$(fm_backend_target_of_meta "$meta")
  [ "$target" = "fmses:fm-100" ] || fail "unparked task target should be fmses:fm-100, got '$target'"

  # Parked task: default suppresses target
  echo "parked=1" >> "$meta"
  target=$(fm_backend_target_of_meta "$meta")
  [ -z "$target" ] || fail "parked task target should be suppressed by default, got '$target'"

  # Parked task: --include-parked overrides suppression
  target=$(fm_backend_target_of_meta "$meta" --include-parked)
  [ "$target" = "fmses:fm-100" ] || fail "target with --include-parked should be fmses:fm-100, got '$target'"

  target=$(fm_backend_target_of_meta --include-parked "$meta")
  [ "$target" = "fmses:fm-100" ] || fail "target with leading --include-parked should be fmses:fm-100, got '$target'"

  # Explicit parked=0 resolves target
  sed -i 's/parked=1/parked=0/' "$meta"
  target=$(fm_backend_target_of_meta "$meta")
  [ "$target" = "fmses:fm-100" ] || fail "unparked task (parked=0) target should be fmses:fm-100, got '$target'"

  pass "backend: target suppression hides parked tasks by default and respects --include-parked"
}

# --- 3. crew state reporting ------------------------------------------------
test_crew_state_reports_parked() {
  local dir d out
  dir=$(new_case crew-state)
  setup_task "$dir" t1 claude
  echo "parked=1" >> "$dir/home/state/t1.meta"
  echo "parked_note=waiting for dispatch" >> "$dir/home/state/t1.meta"

  out=$(env FM_HOME="$dir/home" "$CREW_STATE" t1)
  assert_contains "$out" "state: parked" "crew state should report state: parked"
  assert_contains "$out" "source: none" "crew state should report source: none"
  assert_contains "$out" "seat parked with unlanded work" "crew state should report parked reason"
  assert_contains "$out" "waiting for dispatch" "crew state should include parked note"

  # Without note
  sed -i '/^parked_note=/d' "$dir/home/state/t1.meta"
  out=$(env FM_HOME="$dir/home" "$CREW_STATE" t1)
  assert_contains "$out" "state: parked · source: none · seat parked with unlanded work" "crew state without note"

  pass "crew-state: parked tasks report state: parked · source: none"
}

# --- 4. park and unpark lifecycle -------------------------------------------
test_park_and_unpark_lifecycle() {
  local dir out rc meta w_key
  dir=$(new_case lifecycle)
  setup_task "$dir" t1 claude
  printf 'claude' > "$dir/fake/command"
  meta="$dir/home/state/t1.meta"
  w_key="fmses_fm-t1"

  # Seed stale and pause markers
  touch "$dir/home/state/.stale-$w_key" "$dir/home/state/.stale-since-$w_key" "$dir/home/state/.paused-$w_key"

  # Park while agent is running
  out=$(run_control "$dir" t1 park --note "paused awaiting upstream review"); rc=$?
  expect_code 0 "$rc" "parking running agent should succeed"
  assert_contains "$out" "parked t1 exit_result=stopped" "park should report stopped"
  assert_contains "$out" "note=\"paused awaiting upstream review\"" "park should echo note"

  [ "$(fm_meta_get "$meta" parked)" = 1 ] || fail "metadata should record parked=1"
  [ "$(fm_meta_get "$meta" parked_note)" = "paused awaiting upstream review" ] || fail "metadata should record parked_note"
  [ -n "$(fm_meta_get "$meta" parked_at)" ] || fail "metadata should record parked_at"

  # Markers must be cleared
  [ ! -e "$dir/home/state/.stale-$w_key" ] || fail "stale marker should be removed on park"
  [ ! -e "$dir/home/state/.stale-since-$w_key" ] || fail "stale-since marker should be removed on park"
  [ ! -e "$dir/home/state/.paused-$w_key" ] || fail "paused marker should be removed on park"

  # Park again while already stopped (idempotent)
  out=$(run_control "$dir" t1 park); rc=$?
  expect_code 0 "$rc" "parking already-stopped agent should succeed"
  assert_contains "$out" "parked t1 exit_result=already-stopped" "idempotent park reports already-stopped"

  # Unpark
  out=$(run_control "$dir" t1 unpark); rc=$?
  expect_code 0 "$rc" "unparking should succeed"
  assert_contains "$out" "unparked t1" "unpark output reports unparked"
  [ -z "$(fm_meta_get "$meta" parked)" ] || fail "parked should be cleared after unpark"
  [ -z "$(fm_meta_get "$meta" parked_note)" ] || fail "parked_note should be cleared after unpark"

  pass "control: park and unpark lifecycle manages agent, metadata, and markers cleanly"
}

# --- 5. teardown refuses unlanded work on parked task -----------------------
test_teardown_refuses_parked_task_with_unlanded_work() {
  local dir wt proj head out rc
  dir=$(new_case teardown-refusal)
  setup_task "$dir" t1 claude
  wt="$dir/wt-t1"
  proj="$dir/proj-t1"

  # Create an unpushed / unlanded commit in the task worktree
  printf 'unlanded progress\n' >> "$wt/progress.txt"
  git -C "$wt" add progress.txt
  git -C "$wt" commit -q -m "unlanded commit"
  head=$(git -C "$wt" rev-parse HEAD)

  # Park the seat
  run_control "$dir" t1 park >/dev/null || fail "parking task should succeed"
  [ "$(fm_meta_get "$dir/home/state/t1.meta" parked)" = 1 ] || fail "task should be parked"

  # Run teardown: MUST REFUSE because work is unlanded
  set +e
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$TEARDOWN" t1 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "teardown of parked seat with unlanded work must refuse"
  assert_contains "$out" "REFUSED" "teardown refusal should say REFUSED"

  # Unlanded commit and worktree must remain 100% intact
  [ -d "$wt" ] || fail "worktree must not be removed"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] || fail "worktree head must be unchanged"
  [ -f "$dir/home/state/t1.meta" ] || fail "task metadata must remain intact"

  pass "teardown: unlanded-work refusal stays authoritative and preserves unlanded commits"
}

# --- 6. watcher omits parked windows and emits no stale wake ----------------
test_watcher_omits_parked_windows_and_emits_no_stale_wake() {
  local dir home state windows w_key out
  dir=$(new_case watcher)
  setup_task "$dir" t1 claude
  home="$dir/home"
  state="$home/state"
  w_key="fmses_fm-t1"

  # Agent is stopped
  printf 'zsh' > "$dir/fake/command"

  # When unparked: recorded_windows includes the task window
  windows=$(
    FM_HOME="$home" STATE="$state" SCRIPT_DIR="$ROOT/bin"
    # shellcheck source=/dev/null
    . "$WATCH"
    recorded_windows
  )
  assert_contains "$windows" "fmses:fm-t1" "unparked task window must be probed by watcher"

  # Park the task
  run_control "$dir" t1 park >/dev/null || fail "parking task should succeed"
  [ "$(fm_meta_get "$state/t1.meta" parked)" = 1 ] || fail "task should be parked"

  # When parked: recorded_windows DOES NOT include the task window
  windows=$(
    FM_HOME="$home" STATE="$state" SCRIPT_DIR="$ROOT/bin"
    # shellcheck source=/dev/null
    . "$WATCH"
    recorded_windows
  )
  assert_not_contains "$windows" "fmses:fm-t1" "parked task window must be omitted from recorded_windows"

  # Run real watcher in the background for several poll cycles
  out_log="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" STATE="$state" \
    FM_POLL=0.05 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out_log" 2>&1 &
  watch_pid=$!
  sleep 0.5
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true

  # Check that NO stale marker was created across the cycles
  [ ! -e "$state/.stale-$w_key" ] || fail "stale marker must not be created for parked window"
  [ ! -e "$state/.stale-since-$w_key" ] || fail "stale-since marker must not be created for parked window"
  ! grep -q "stale: fmses:fm-t1" "$out_log" || fail "watcher must not emit stale wake for parked window"

  # Unpark and verify recorded_windows probes the window again
  run_control "$dir" t1 unpark >/dev/null || fail "unparking task should succeed"
  windows=$(
    FM_HOME="$home" STATE="$state" SCRIPT_DIR="$ROOT/bin"
    # shellcheck source=/dev/null
    . "$WATCH"
    recorded_windows
  )
  assert_contains "$windows" "fmses:fm-t1" "unparked task window must be restored to recorded_windows"

  pass "watcher: parked task is omitted from recorded_windows with zero stale wakes across cycles"
}

test_control_verbs_allowlist
test_backend_target_of_meta_probe_suppression
test_crew_state_reports_parked
test_park_and_unpark_lifecycle
test_teardown_refuses_parked_task_with_unlanded_work
test_watcher_omits_parked_windows_and_emits_no_stale_wake

echo "all fm-parked-seat tests passed"
