#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
last=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
session=$last
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg socket "$default_socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "pane list")
    pane=
    [ ! -f "$state/$session.pane" ] || pane=$(cat "$state/$session.pane")
    if [ -n "$pane" ]; then
      jq -nc --arg pane "$pane" --arg session "$session" \
        '{id:"cli:pane:list",result:{type:"pane_list",panes:[{pane_id:$pane,workspace_id:($session + ":w1"),tab_id:($session + ":t1")}]}}'
    else
      printf '%s\n' '{"id":"cli:pane:list","result":{"type":"pane_list","panes":[]}}'
    fi
    ;;
  "--session $session")
    [ "$lab_state" = running ] || exit 94
    printf '%s\n' "$$" > "$state/$session.client-pid"
    if [ "${FM_FAKE_HERDR_BOOTSTRAP_NO_PANE:-}" != 1 ]; then
      printf '%s\n' "$session:w1:p1" > "$state/$session.pane"
    fi
    exec "$FM_FAKE_HERDR_REAL_SLEEP" 300
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_FAKE_HERDR_BOOTSTRAP_NO_PANE="${FM_FAKE_HERDR_BOOTSTRAP_NO_PANE:-}" \
    FM_HERDR_LAB_BOOTSTRAP_MAX_ATTEMPTS="${FM_HERDR_LAB_BOOTSTRAP_MAX_ATTEMPTS:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse bootstrap-pane"
  status=0
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

test_bootstrap_pane_is_scoped_owned_and_cleaned() {
  local name="fm-lab-bootstrap-$$" before out pane pid line
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "bootstrap fixture provision failed"
  before=$(cat "$TRIPWIRES/$name.fleet-state.json")
  [ "$(run_with_fake fm_herdr_lab_cli "$name" pane list | jq '.result.panes | length')" = 0 ] \
    || fail "freshly provisioned lab was not a zero-pane fixture"

  out=$(HERDR_SESSION=default run_with_fake fm_herdr_lab_bootstrap_pane "$name") \
    || fail "bootstrap-pane failed"
  [ "$(printf '%s' "$out" | jq -r '.session')" = "$name" ] \
    || fail "bootstrap result did not bind the named session"
  pane=$(printf '%s' "$out" | jq -r '.pane_id // empty')
  [ "$pane" = "$name:w1:p1" ] || fail "bootstrap result did not return the authoritative pane id: $out"
  pid=$(printf '%s' "$out" | jq -r '.client_pid // empty')
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
    || fail "bootstrap result did not identify a live owned client PID: $out"
  assert_present "$TRIPWIRES/$name.bootstrap-client/client.state" \
    "bootstrap did not persist its owned client state"

  run_with_fake fm_herdr_lab_stop "$name" >/dev/null || fail "stop did not clean the bootstrap client"
  kill -0 "$pid" 2>/dev/null && fail "stop left the owned bootstrap client running"
  assert_absent "$TRIPWIRES/$name.bootstrap-client" "stop left bootstrap client state behind"
  [ "$(cat "$TRIPWIRES/$name.fleet-state.json")" = "$before" ] \
    || fail "stop changed the default-session fleet tripwire"
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null \
    || fail "repeated stop was not safe for the already-clean bootstrap client"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after bootstrap stop failed"
  [ "$(cat "$FAKE_STATE/default-socket")" = '/home/test/.config/herdr/herdr.sock' ] \
    || fail "bootstrap lifecycle changed the default-session evidence"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "bootstrap lifecycle Herdr call lacks the exact trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  grep -Fx -- "--session $name" "$FAKE_LOG" >/dev/null \
    || fail "bootstrap client did not attach with the exact trailing named session"
  pass "fm-herdr-lab: zero-pane bootstrap is scoped, machine-readable, owned, and cleanly repeatable"
}

test_bootstrap_pane_failure_is_bounded_and_cleans_client() {
  local name="fm-lab-bootstrap-timeout-$$" status=0 client_pid
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "bootstrap timeout fixture provision failed"
  FM_HERDR_LAB_BOOTSTRAP_MAX_ATTEMPTS=1 FM_FAKE_HERDR_BOOTSTRAP_NO_PANE=1 \
    run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "zero-pane bootstrap timeout must fail boundedly"
  assert_absent "$TRIPWIRES/$name.bootstrap-client" \
    "failed bootstrap left owned client state behind"
  client_pid=$(cat "$FAKE_STATE/$name.client-pid")
  kill -0 "$client_pid" 2>/dev/null && fail "failed bootstrap left its owned client running"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "failed bootstrap removed the lab fleet-state tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after bootstrap timeout failed"
  pass "fm-herdr-lab: bootstrap pane wait is bounded and failure cleans only its owned client"
}

test_bootstrap_pane_refuses_mismatched_ownership() {
  local name="fm-lab-bootstrap-owner-$$" dir status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "bootstrap ownership fixture provision failed"
  dir="$TRIPWIRES/$name.bootstrap-client"
  mkdir "$dir"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t\n' \
    'fm-lab-someone-else' 999999 1 999998 1 'fm-herdr-lab:fm-lab-someone-else:1:1:1' \
    > "$dir/client.state"

  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bootstrap-pane must refuse mismatched ownership state"
  status=0
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse mismatched bootstrap ownership state"
  [ "$(cat "$FAKE_STATE/$name")" = running ] \
    || fail "ownership refusal stopped the named lab"
  ! grep -F "session stop $name" "$FAKE_LOG" >/dev/null \
    || fail "ownership refusal reached a destructive Herdr call"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t\n' \
    "$name" 999999 1 999998 1 "fm-herdr-lab:${name}:1:1:1" > "$dir/client.state"
  status=0
  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bootstrap-pane must refuse stale recorded ownership"

  rm -f "$dir/client.state"
  rmdir "$dir"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after removing foreign fixture failed"
  pass "fm-herdr-lab: bootstrap and cleanup fail closed on mismatched ownership"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
test_bootstrap_pane_is_scoped_owned_and_cleaned
test_bootstrap_pane_failure_is_bounded_and_cleans_client
test_bootstrap_pane_refuses_mismatched_ownership
