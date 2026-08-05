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
args=("$@")
count=${#args[@]}
[ "$count" -ge 2 ] && [ "${args[$((count - 2))]}" = --session ] || {
  echo "fake herdr: missing trailing --session" >&2
  exit 90
}
session=${args[$((count - 1))]}
expected=
command_args=()
index=0
while [ "$index" -lt "$((count - 2))" ]; do
  arg=${args[$index]}
  if [ "$arg" = --expected-generation ]; then
    index=$((index + 1))
    [ "$index" -lt "$((count - 2))" ] || exit 89
    expected=${args[$index]}
  else
    command_args+=("$arg")
  fi
  index=$((index + 1))
done
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")
socket_dir="$state/sessions/$session"
socket="$socket_dir/herdr.sock"
generation_file="$state/$session.generation"
generation=
[ ! -f "$generation_file" ] || generation=$(cat "$generation_file")

if [ -n "$expected" ] && [ "$expected" != "$generation" ]; then
  printf '%s\n' '{"error":{"code":"generation_mismatch"}}' >&2
  exit 99
fi

first=${command_args[0]:-}
second=${command_args[1]:-}

case "$first $second" in
  "session list")
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg default_socket "$default_socket" --arg socket "$socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$default_socket},{default:false,name:$name,running:$running,socket_path:$socket}]}'
    fi
    ;;
  "server ")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    counter=0
    [ ! -f "$state/generation-counter" ] || counter=$(cat "$state/generation-counter")
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$state/generation-counter"
    printf -v suffix '%012x' "$counter"
    generation="00000000-0000-4000-8000-$suffix"
    mkdir -p "$socket_dir"
    : > "$socket"
    printf '%s\n' running > "$state/$session"
    printf '%s\n' "$generation" > "$generation_file"
    if [ "${FM_FAKE_HERDR_FOREIGN_PROVISION:-}" = 1 ]; then
      exit 0
    fi
    printf '%s\n' "$$" > "$state/$session.server-pid"
    exec "$FM_FAKE_HERDR_REAL_SLEEP" 300
    ;;
  "status server")
    if [ "$lab_state" = running ]; then
      if [ "${FM_FAKE_HERDR_STATUS_OMIT_GENERATION:-}" = 1 ]; then
        jq -nc --arg session "$session" --arg socket "$socket" \
          '{status:"running",running:true,session:$session,socket:$socket}'
      else
        jq -nc --arg generation "$generation" --arg session "$session" --arg socket "$socket" \
          '{status:"running",running:true,generation:$generation,session:$session,socket:$socket}'
      fi
      [ "${FM_FAKE_HERDR_STATUS_EXTRA_RECORD:-}" != 1 ] || printf '%s\n' '{"extra":true}'
    else
      jq -nc --arg session "$session" --arg socket "$socket" \
        '{status:"not_running",running:false,generation:null,session:$session,socket:$socket}'
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
  "workspace create")
    [ "$lab_state" = running ] || exit 95
    if [ "${FM_FAKE_HERDR_BOOTSTRAP_NO_PANE:-}" != 1 ]; then
      printf '%s\n' "$session:w1:p1" > "$state/$session.pane"
    fi
    [ "${FM_FAKE_HERDR_WORKSPACE_CREATE_FAIL_AFTER_PANE:-}" != 1 ] || exit 98
    if [ "${FM_FAKE_HERDR_WORKSPACE_CREATE_MALFORMED:-}" = 1 ]; then
      printf '%s\n' '{"result":{"workspace":{}}}'
      exit 0
    fi
    jq -nc --arg session "$session" \
      '{result:{workspace:{workspace_id:($session + ":w1")},tab:{tab_id:($session + ":w1:t1")},root_pane:{pane_id:($session + ":w1:p1")}}}'
    ;;
  " ")
    [ -n "$expected" ] || exit 88
    [ "$lab_state" = running ] || exit 94
    printf '%s\n' "$$" > "$state/$session.client-pid"
    if [ "${FM_FAKE_HERDR_BOOTSTRAP_NO_PANE:-}" != 1 ]; then
      printf '%s\n' "$session:w1:p1" > "$state/$session.pane"
    fi
    exec "$FM_FAKE_HERDR_REAL_SLEEP" 300
    ;;
  "pane close")
    [ -f "$state/$session.pane" ] && [ "$(cat "$state/$session.pane")" = "${command_args[2]:-}" ] || exit 96
    rm -f "$state/$session.pane"
    if [ "${FM_FAKE_HERDR_PANE_CLOSE_REPLACEMENT:-}" = 1 ]; then
      printf '%s\n' "$session:w1:p2" > "$state/$session.pane"
    fi
    printf '%s\n' '{"ok":true}'
    ;;
  "pane get")
    if [ -f "$state/$session.pane" ] && [ "$(cat "$state/$session.pane")" = "${command_args[2]:-}" ]; then
      jq -nc --arg pane "${command_args[2]}" --arg session "$session" \
        '{result:{pane:{pane_id:$pane,workspace_id:($session + ":w1")}}}'
    else
      jq -nc --arg pane "${command_args[2]:-}" \
        '{error:{code:"pane_not_found",message:("pane " + $pane + " not found")}}' >&2
      exit 1
    fi
    ;;
  "session stop")
    [ "${command_args[2]:-}" = "$session" ] || exit 91
    [ "${FM_FAKE_HERDR_STOP_FAIL:-}" != 1 ] || exit 97
    if [ -f "$state/$session.server-pid" ]; then
      kill -TERM "$(cat "$state/$session.server-pid")" 2>/dev/null || true
      rm -f "$state/$session.server-pid"
    fi
    rm -f "$socket"
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "${command_args[2]:-}" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    if [ -f "$state/$session.server-pid" ]; then
      kill -TERM "$(cat "$state/$session.server-pid")" 2>/dev/null || true
      rm -f "$state/$session.server-pid"
    fi
    rm -rf "$socket_dir"
    rm -f "$generation_file" "$state/$session.pane"
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

cleanup_fake_servers() {
  local pid_file pid
  for pid_file in "$FAKE_STATE"/*.server-pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file")
    kill -TERM "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_fake_servers EXIT

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_FAKE_HERDR_STOP_FAIL="${FM_FAKE_HERDR_STOP_FAIL:-}" \
    FM_FAKE_HERDR_BOOTSTRAP_NO_PANE="${FM_FAKE_HERDR_BOOTSTRAP_NO_PANE:-}" \
    FM_FAKE_HERDR_FOREIGN_PROVISION="${FM_FAKE_HERDR_FOREIGN_PROVISION:-}" \
    FM_FAKE_HERDR_WORKSPACE_CREATE_FAIL_AFTER_PANE="${FM_FAKE_HERDR_WORKSPACE_CREATE_FAIL_AFTER_PANE:-}" \
    FM_FAKE_HERDR_WORKSPACE_CREATE_MALFORMED="${FM_FAKE_HERDR_WORKSPACE_CREATE_MALFORMED:-}" \
    FM_FAKE_HERDR_STATUS_EXTRA_RECORD="${FM_FAKE_HERDR_STATUS_EXTRA_RECORD:-}" \
    FM_FAKE_HERDR_STATUS_OMIT_GENERATION="${FM_FAKE_HERDR_STATUS_OMIT_GENERATION:-}" \
    FM_FAKE_HERDR_PANE_CLOSE_REPLACEMENT="${FM_FAKE_HERDR_PANE_CLOSE_REPLACEMENT:-}" \
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
  local name='' generation line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  generation=$(jq -er '.generation' "$TRIPWIRES/$name.session-identity.json") \
    || fail "provision did not record the authoritative generation"
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
  run_with_fake fm_herdr_lab_cli "$name" status --expected-generation 00000000-0000-4000-8000-000000000001 \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied generation scope must be refused"
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
  run_with_fake fm_herdr_lab_teardown "$name" || fail "repeated teardown was not idempotent"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --expected-generation $generation --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --expected-generation $generation --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" \
    | grep -F "status server --json --expected-generation $generation --session $name" >/dev/null \
    || fail "stop was not immediately preceded by an authoritative generation check"
  sed -n "$((stop_line - 2))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop generation check was not preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse bootstrap-pane"
  status=0
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  ! tail -n +$((before + 1)) "$FAKE_LOG" \
    | grep -v -Fx -- "session list --json --session $name" >/dev/null \
    || fail "missing tripwire reached a destructive Herdr call"
  pass "fm-herdr-lab: missing tripwire refuses destructive teardown calls"
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
  local name="fm-lab-reprovision-$$" old_generation new_generation
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  old_generation=$(cat "$FAKE_STATE/$name.generation")
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  new_generation=$(cat "$FAKE_STATE/$name.generation")
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  [ "$new_generation" != "$old_generation" ] || fail "re-provision did not bind a fresh server generation"
  grep -F "session delete $name --json --expected-generation $old_generation --session $name" "$FAKE_LOG" >/dev/null \
    || fail "re-provision did not delete the exact stopped generation before restart"
  grep -F "server --session $name" "$FAKE_LOG" >/dev/null \
    || fail "re-provision did not start a fresh named server"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab re-provisions through its exact retired generation"
}

test_concurrent_run_waits_for_live_lifecycle_lock() {
  local name="fm-lab-lock-wait-$$" lock owner_pid owner_start run_pid status=0
  run_with_fake fm_herdr_lab_provision "$name" || fail "lock-wait fixture provision failed"
  lock="$TRIPWIRES/$name.lifecycle.lock"
  "$REAL_SLEEP" 30 &
  owner_pid=$!
  owner_start=$(fm_herdr_lab_process_start "$owner_pid") || fail "could not identify lock-wait fixture owner"
  printf '%s\t%s\t%s\t%s\n' \
    "$name" "$owner_pid" "$owner_start" "fm-herdr-lab-lock:${name}:${owner_pid}:1" > "$lock"

  FM_HERDR_LAB_LOCK_WAIT_ATTEMPTS=100 run_with_fake fm_herdr_lab_run "$name" workspace list >/dev/null &
  run_pid=$!
  "$REAL_SLEEP" 0.05
  kill -0 "$run_pid" 2>/dev/null || fail "concurrent run failed instead of waiting for the live lifecycle lock"
  rm -f "$lock"
  wait "$run_pid" || status=$?
  expect_code 0 "$status" "concurrent run must continue after the live lifecycle lock is released"

  kill -TERM "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
  run_with_fake fm_herdr_lab_teardown "$name" || fail "lock-wait fixture teardown failed"
  pass "fm-herdr-lab: concurrent run waits boundedly for a live lifecycle operation"
}

test_dead_lifecycle_lock_is_reclaimed() {
  local name="fm-lab-dead-lock-$$" lock owner_pid owner_start
  lock="$TRIPWIRES/$name.lifecycle.lock"
  "$REAL_SLEEP" 30 &
  owner_pid=$!
  owner_start=$(fm_herdr_lab_process_start "$owner_pid") || fail "could not identify dead-lock fixture owner"
  printf '%s\t%s\t%s\t%s\n' \
    "$name" "$owner_pid" "$owner_start" "fm-herdr-lab-lock:${name}:${owner_pid}:1" > "$lock"
  kill -TERM "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true

  run_with_fake fm_herdr_lab_provision "$name" || fail "dead lifecycle lock was not reclaimed"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "dead-lock fixture teardown failed"
  pass "fm-herdr-lab: a lifecycle lock whose owner exited is reclaimed"
}

test_stopped_session_refuses_foreign_restart_and_stop() {
  local name="fm-lab-stopped-foreign-$$" status=0 foreign_stop_line
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "stopped-session ownership fixture provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "stopped-session ownership fixture stop failed"
  FM_FAKE_HERDR_FOREIGN_PROVISION=1 run_with_fake herdr server --session "$name" \
    >/dev/null || fail "foreign stopped-session restart fixture failed"
  FM_FAKE_HERDR_FOREIGN_PROVISION=1 run_with_fake herdr session stop "$name" --json --session "$name" \
    >/dev/null || fail "foreign stopped-session stop fixture failed"
  foreign_stop_line=$(wc -l < "$FAKE_LOG" | tr -d ' ')

  run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "re-provision must reject a foreign restart-stop of a retained session"
  ! tail -n +$((foreign_stop_line + 1)) "$FAKE_LOG" | grep -F "session stop $name --json --session $name" >/dev/null \
    || fail "foreign stopped-session rejection reached helper session stop"
  status=0
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "teardown must reject a foreign restart-stop of a retained session"
  ! grep -F "session delete $name --json --session $name" "$FAKE_LOG" >/dev/null \
    || fail "foreign stopped-session rejection reached session delete"

  rm -f "$TRIPWIRES/$name.fleet-state.json" "$TRIPWIRES/$name.session-identity.json" "$FAKE_STATE/$name"
  rm -rf "$FAKE_STATE/sessions/$name"
  pass "fm-herdr-lab: stopped-session ownership rejects a foreign restart-stop before adoption"
}

test_stopped_receipt_rejects_precommit_generation_race() {
  local name="fm-lab-stop-receipt-race-$$" saved status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "stop-receipt race fixture provision failed"
  saved=$(declare -f fm_herdr_lab_write_stopped_session_identity)
  eval "$(declare -f fm_herdr_lab_write_stopped_session_identity | sed '1s/fm_herdr_lab_write_stopped_session_identity/fm_herdr_lab_write_stopped_session_identity_original/')"
  fm_herdr_lab_write_stopped_session_identity() {
    "$REAL_SLEEP" 0.02
    FM_FAKE_HERDR_FOREIGN_PROVISION=1 run_with_fake herdr server --session "$name" \
      >/dev/null || fail "foreign stop-receipt restart fixture failed"
    FM_FAKE_HERDR_FOREIGN_PROVISION=1 run_with_fake herdr session stop "$name" --json --session "$name" \
      >/dev/null || fail "foreign stop-receipt stop fixture failed"
    fm_herdr_lab_write_stopped_session_identity_original "$@"
  }
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  eval "$saved"
  unset -f fm_herdr_lab_write_stopped_session_identity_original
  expect_code 0 "$status" "stop should retain its receipt when a stopped generation is replaced after the guarded mutation"
  assert_present "$TRIPWIRES/$name.stop-generation.json" \
    "stop race discarded its durable generation receipt"
  [ "$(jq -r '.state' "$TRIPWIRES/$name.session-identity.json")" = stopped ] \
    || fail "stop race did not retain its stopped-generation identity"
  status=0
  run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "re-provision must reject the raced stop generation"
  grep -F "session delete $name --json --expected-generation" "$FAKE_LOG" >/dev/null \
    || fail "stop-generation race did not reach the core-owned atomic generation check"
  rm -f "$TRIPWIRES/$name.fleet-state.json" "$TRIPWIRES/$name.session-identity.json" \
    "$TRIPWIRES/$name.stop-generation.json" "$FAKE_STATE/$name"
  rm -rf "$FAKE_STATE/sessions/$name"
  pass "fm-herdr-lab: stopped identity defers replacement refusal to the core generation guard"
}

test_prepare_uses_guarded_owned_provisioning() {
  local name="fm-lab-prepare-owned-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_prepare "$name" || fail "prepare did not use guarded provisioning"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "prepare left the named session stopped"
  assert_present "$TRIPWIRES/$name.session-identity.json" \
    "prepare did not bind the helper-owned session identity"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "prepare-created session could not be cleaned"
  pass "fm-herdr-lab: prepare compatibility uses the owned provision and cleanup path"
}

test_provision_refuses_posthoc_foreign_session() {
  local name="fm-lab-foreign-provision-$$" status=0
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FOREIGN_PROVISION=1 run_with_fake fm_herdr_lab_provision "$name" \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "provision must reject a session not bound to its live server launch"
  assert_present "$TRIPWIRES/$name.session-claim.json" \
    "ambiguous provision removed its creation-boundary evidence"
  assert_absent "$TRIPWIRES/$name.session-identity.json" \
    "ambiguous provision adopted a foreign same-name session"
  ! grep -F "session stop $name" "$FAKE_LOG" >/dev/null \
    || fail "ambiguous provision reached session stop"
  rm -f "$TRIPWIRES/$name.fleet-state.json" "$TRIPWIRES/$name.session-claim.json" "$FAKE_STATE/$name"
  rm -rf "$FAKE_STATE/sessions/$name"
  pass "fm-herdr-lab: provision binds ownership at the server creation boundary"
}

test_provision_refuses_stale_bootstrap_evidence() {
  local name="fm-lab-stale-bootstrap-dir-$$" retiring_name="fm-lab-stale-retiring-$$" status=0
  : > "$FAKE_LOG"
  mkdir -p "$TRIPWIRES/$name.bootstrap-client"
  run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "provision must reject a stale bootstrap directory"
  assert_absent "$TRIPWIRES/$name.session-claim.json" \
    "stale bootstrap evidence left a pending session claim"
  ! grep -F "server --session $name" "$FAKE_LOG" >/dev/null \
    || fail "stale bootstrap directory reached named server creation"
  rmdir "$TRIPWIRES/$name.bootstrap-client"

  : > "$TRIPWIRES/$retiring_name.bootstrap-client.retiring.state"
  status=0
  run_with_fake fm_herdr_lab_provision "$retiring_name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "provision must reject stale retiring evidence"
  assert_absent "$TRIPWIRES/$retiring_name.session-claim.json" \
    "stale retiring evidence left a pending session claim"
  ! grep -F "server --session $retiring_name" "$FAKE_LOG" >/dev/null \
    || fail "stale retiring evidence reached named server creation"
  rm -f "$TRIPWIRES/$retiring_name.bootstrap-client.retiring.state"
  pass "fm-herdr-lab: same-name provisioning refuses stale bootstrap lifecycle evidence"
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

test_stop_failure_is_propagated() {
  local name="fm-lab-stop-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "stop-failure fixture provision failed"
  FM_FAKE_HERDR_STOP_FAIL=1 run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed session stop must fail the guarded stop"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "failed session stop changed the named lab state"
  ! grep -F "session delete $name" "$FAKE_LOG" >/dev/null || fail "failed session stop reached deletion"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after a propagated stop failure failed"
  pass "fm-herdr-lab: session stop failures remain destructive-call barriers"
}

test_bootstrap_state_failure_cleans_client_and_child() {
  local name="fm-lab-bootstrap-state-failure-$$" status=0 saved attach_pid
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "bootstrap state-failure fixture provision failed"
  saved=$(declare -f fm_herdr_lab_write_bootstrap_record)
  eval "$(declare -f fm_herdr_lab_write_bootstrap_record | sed '1s/fm_herdr_lab_write_bootstrap_record/fm_herdr_lab_write_bootstrap_record_original/')"
  fm_herdr_lab_write_bootstrap_record() {
    [ -n "${2:-}" ] && return 1
    fm_herdr_lab_write_bootstrap_record_original "$@"
  }
  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  eval "$saved"
  unset -f fm_herdr_lab_write_bootstrap_record_original
  expect_code 1 "$status" "bootstrap state write failure must fail"
  assert_absent "$TRIPWIRES/$name.bootstrap-client" \
    "bootstrap state-write rollback left client state behind"
  attach_pid=$(cat "$FAKE_STATE/$name.client-pid")
  kill -0 "$attach_pid" 2>/dev/null && fail "bootstrap state-write rollback left its PTY child running"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after bootstrap state-write failure failed"
  pass "fm-herdr-lab: state-write rollback stops both owned bootstrap processes"
}

test_bootstrap_pending_zero_pids_cleanup() {
  local name="fm-lab-bootstrap-zero-pids-$$" dir pane owner
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "zero-PID fixture provision failed"
  dir="$TRIPWIRES/$name.bootstrap-client"
  pane="$name:w1:p1"
  owner="fm-herdr-lab:${name}:1:1:1"
  mkdir "$dir"
  chmod 700 "$dir"
  run_with_fake fm_herdr_lab_write_bootstrap_record \
    "$name" "" "" "" "" "$owner" "$pane" || fail "zero-PID pending record write failed"
  printf '%s\n' "$pane" > "$FAKE_STATE/$name.pane"
  run_with_fake fm_herdr_lab_stop_bootstrap_client "$name" 1 \
    || fail "zero-PID pending cleanup did not close its exact pane"
  assert_absent "$TRIPWIRES/$name.bootstrap-client" \
    "zero-PID pending cleanup left its retired state behind"
  assert_absent "$FAKE_STATE/$name.pane" \
    "zero-PID pending cleanup left its exact pane behind"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after zero-PID cleanup failed"
  pass "fm-herdr-lab: pending zero PIDs are absent before cleanup ownership checks"
}

test_bootstrap_journals_client_before_pty_discovery() {
  local name="fm-lab-bootstrap-partial-client-$$" marker="$TMP_ROOT/partial-client.marker" saved status=0 client_pid
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "partial-client fixture provision failed"
  saved=$(declare -f fm_herdr_lab_single_child_pid)
  fm_herdr_lab_single_child_pid() {
    fm_herdr_lab_read_bootstrap_record "$name" || return 1
    if [ "$FM_HERDR_LAB_BOOTSTRAP_PID" = "$1" ] \
       && [ "$FM_HERDR_LAB_BOOTSTRAP_PID" -gt 1 ] \
       && [ "$FM_HERDR_LAB_BOOTSTRAP_START" != pending ] \
       && [ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_PID" -eq 0 ] \
       && [ "$FM_HERDR_LAB_BOOTSTRAP_ATTACH_START" = pending ]; then
      : > "$marker"
    fi
    return 1
  }
  FM_HERDR_LAB_BOOTSTRAP_MAX_ATTEMPTS=1 \
    run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  eval "$saved"
  expect_code 1 "$status" "missing PTY discovery must fail after partial client journaling"
  assert_present "$marker" "bootstrap client PID/start identity was not journaled before PTY discovery"
  assert_absent "$TRIPWIRES/$name.bootstrap-client" \
    "verified partial client cleanup left lifecycle evidence behind"
  client_pid=$(cat "$FAKE_STATE/$name.client-pid")
  kill -0 "$client_pid" 2>/dev/null && fail "partial client cleanup left its owned PTY child running"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after partial-client cleanup failed"
  pass "fm-herdr-lab: client PID/start identity is journaled before PTY discovery"
}

test_bootstrap_workspace_failure_retains_unresolved_pane() {
  local name="fm-lab-bootstrap-workspace-failure-$$" status=0 saved server_pid
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "workspace-failure fixture provision failed"
  saved=$(declare -f fm_herdr_lab_guarded_raw)
  eval "$(declare -f fm_herdr_lab_guarded_raw | sed '1s/fm_herdr_lab_guarded_raw/fm_herdr_lab_guarded_raw_original/')"
  # shellcheck disable=SC2329
  fm_herdr_lab_guarded_raw() {
    local out
    out=$(fm_herdr_lab_guarded_raw_original "$@") || {
      if [ "${3:-} ${4:-}" = "workspace create" ]; then
        printf '%s\n' "$name:foreign:w9:p9" > "$FAKE_STATE/$name.pane"
      fi
      return 1
    }
    printf '%s\n' "$out"
  }
  FM_FAKE_HERDR_WORKSPACE_CREATE_FAIL_AFTER_PANE=1 \
    run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  eval "$saved"
  unset -f fm_herdr_lab_guarded_raw_original
  expect_code 1 "$status" "workspace creation failure after pane visibility must fail"
  assert_present "$TRIPWIRES/$name.bootstrap-client/client.state" \
    "workspace creation failure discarded unresolved pane evidence"
  [ "$(cat "$FAKE_STATE/$name.pane")" = "$name:foreign:w9:p9" ] \
    || fail "workspace creation failure changed the foreign pane fixture"
  ! grep -F "pane close $name:foreign:w9:p9" "$FAKE_LOG" >/dev/null \
    || fail "pending cleanup inferred ownership from a single foreign pane"
  status=0
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must retain unresolved pending pane evidence"
  assert_present "$TRIPWIRES/$name.bootstrap-client/client.state" \
    "stop discarded unresolved pending pane evidence"
  ! grep -F "session stop $name" "$FAKE_LOG" >/dev/null \
    || fail "unresolved pending pane reached session stop"
  server_pid=$(cat "$FAKE_STATE/$name.server-pid")
  kill -TERM "$server_pid" 2>/dev/null || true
  rm -rf "$TRIPWIRES/$name.bootstrap-client" "$FAKE_STATE/sessions/$name"
  rm -f "$TRIPWIRES/$name.fleet-state.json" "$TRIPWIRES/$name.session-identity.json" \
    "$FAKE_STATE/$name" "$FAKE_STATE/$name.server-pid" "$FAKE_STATE/$name.pane"
  pass "fm-herdr-lab: unresolved pending pane cleanup retains evidence and fails closed"
}

test_bootstrap_post_create_ownership_failure_retains_journal() {
  local name="fm-lab-bootstrap-post-create-owner-$$" status=0 saved server_pid replacement_generation
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "post-create ownership fixture provision failed"
  replacement_generation=00000000-0000-4000-8000-ffffffffffff
  saved=$(declare -f fm_herdr_lab_guarded_raw)
  eval "$(declare -f fm_herdr_lab_guarded_raw | sed '1s/fm_herdr_lab_guarded_raw/fm_herdr_lab_guarded_raw_original/')"
  fm_herdr_lab_guarded_raw() {
    local out
    out=$(fm_herdr_lab_guarded_raw_original "$@") || return 1
    if [ "${3:-} ${4:-}" = "workspace create" ]; then
      printf '%s\n' "$replacement_generation" > "$FAKE_STATE/$name.generation"
    fi
    printf '%s\n' "$out"
  }
  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  eval "$saved"
  unset -f fm_herdr_lab_guarded_raw_original
  expect_code 1 "$status" "post-create generation change must fail bootstrap-pane"
  assert_present "$TRIPWIRES/$name.bootstrap-client/client.state" \
    "post-create ownership failure discarded its mutation journal"
  assert_present "$FAKE_STATE/$name.pane" \
    "post-create ownership failure lost the pane cleanup target"
  status=0
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must retain a post-create journal after ownership mismatch"
  assert_present "$TRIPWIRES/$name.bootstrap-client/client.state" \
    "stop discarded retained post-create cleanup evidence"
  server_pid=$(cat "$FAKE_STATE/$name.server-pid")
  kill -TERM "$server_pid" 2>/dev/null || true
  rm -rf "$TRIPWIRES/$name.bootstrap-client" "$FAKE_STATE/sessions/$name"
  rm -f "$TRIPWIRES/$name.fleet-state.json" "$TRIPWIRES/$name.session-identity.json" \
    "$FAKE_STATE/$name" "$FAKE_STATE/$name.server-pid" "$FAKE_STATE/$name.pane"
  rm -f "$FAKE_STATE/$name.generation"
  pass "fm-herdr-lab: post-create generation failure retains retryable pane evidence"
}

test_bootstrap_record_retirement_retains_state_on_unexpected_entry() {
  local name="fm-lab-bootstrap-retirement-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "retirement fixture provision failed"
  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null || fail "retirement fixture bootstrap failed"
  : > "$TRIPWIRES/$name.bootstrap-client/unexpected.state"
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "unexpected bootstrap state must block record retirement"
  assert_present "$TRIPWIRES/$name.bootstrap-client/client.state" \
    "record retirement removed ownership evidence before safe directory removal"
  rm -f "$TRIPWIRES/$name.bootstrap-client/unexpected.state"
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null || fail "retry after safe state retirement refusal failed"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after record retirement retry failed"
  pass "fm-herdr-lab: ownership records survive an unsafe state-directory retirement"
}

test_bootstrap_pane_is_scoped_owned_and_cleaned() {
  local name="fm-lab-bootstrap-$$" before generation out pane pid line
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "bootstrap fixture provision failed"
  generation=$(jq -er '.generation' "$TRIPWIRES/$name.session-identity.json") \
    || fail "bootstrap fixture has no authoritative generation"
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
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    fail "bootstrap result did not identify a live owned client PID: $out"
  fi
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
  grep -Fx -- "--expected-generation $generation --session $name" "$FAKE_LOG" >/dev/null \
    || fail "bootstrap client did not attach with its generation and exact trailing named session"
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

test_bootstrap_cleanup_accepts_authoritative_pane_absence() {
  local name="fm-lab-bootstrap-pane-absent-$$" out pane
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "pane-absence fixture provision failed"
  out=$(run_with_fake fm_herdr_lab_bootstrap_pane "$name") || fail "pane-absence fixture bootstrap failed"
  pane=$(printf '%s' "$out" | jq -er '.pane_id') || fail "pane-absence fixture has no pane identity"
  FM_FAKE_HERDR_PANE_CLOSE_REPLACEMENT=1 run_with_fake fm_herdr_lab_stop "$name" >/dev/null \
    || fail "stop rejected authoritative absence of its recorded bootstrap pane"
  assert_absent "$TRIPWIRES/$name.bootstrap-client" \
    "authoritative pane absence retained a completed client record"
  [ "$(cat "$FAKE_STATE/$name.pane")" = "$name:w1:p2" ] \
    || fail "cleanup changed the replacement pane after the recorded pane disappeared"
  ! grep -F "pane close $name:w1:p2" "$FAKE_LOG" >/dev/null \
    || fail "cleanup inferred ownership of the replacement pane"
  grep -F "pane get $pane --expected-generation" "$FAKE_LOG" >/dev/null \
    || fail "cleanup did not authoritatively check the recorded pane identity"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "pane-absence fixture teardown failed"
  pass "fm-herdr-lab: cleanup accepts only authoritative absence of its exact recorded pane"
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

test_bootstrap_pane_refuses_recreated_named_session() {
  local name="fm-lab-bootstrap-session-owner-$$" socket_dir status=0 original_generation replacement_generation server_pid
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "bootstrap session-ownership fixture provision failed"
  socket_dir="$FAKE_STATE/sessions/$name"
  original_generation=$(cat "$FAKE_STATE/$name.generation")
  replacement_generation=00000000-0000-4000-8000-eeeeeeeeeeee
  [ "$replacement_generation" != "$original_generation" ] || fail "replacement generation fixture reused the original identity"
  printf '%s\n' "$replacement_generation" > "$FAKE_STATE/$name.generation"

  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bootstrap-pane must refuse a replacement same-name generation"
  status=0
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must refuse a replacement same-name generation"
  ! grep -F "session stop $name" "$FAKE_LOG" >/dev/null \
    || fail "recreated-session refusal reached session stop"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "replacement-generation refusal changed the named lab state"
  status=0
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "teardown must refuse a replacement same-name generation"
  ! grep -F "session delete $name" "$FAKE_LOG" >/dev/null \
    || fail "recreated-session refusal reached session delete"
  server_pid=$(cat "$FAKE_STATE/$name.server-pid")
  kill -TERM "$server_pid" 2>/dev/null || true
  rm -f "$TRIPWIRES/$name.fleet-state.json" "$TRIPWIRES/$name.session-identity.json" \
    "$FAKE_STATE/$name" "$FAKE_STATE/$name.server-pid" "$FAKE_STATE/$name.generation"
  rm -rf "$socket_dir"
  pass "fm-herdr-lab: authoritative generation guards reject stale same-name state"
}

test_identity_parser_refuses_concatenated_records() {
  local name="fm-lab-identity-records-$$" identity original status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "identity parser fixture provision failed"
  identity="$TRIPWIRES/$name.session-identity.json"
  original=$(cat "$identity")
  printf '%s\n%s\n' "$original" "$original" > "$identity"
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "concatenated identity records must be ambiguous"
  ! grep -F "session stop $name" "$FAKE_LOG" >/dev/null \
    || fail "ambiguous identity records reached session stop"
  printf '%s\n' "$original" > "$identity"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "identity parser fixture cleanup failed"
  pass "fm-herdr-lab: session identity accepts exactly one JSON document"
}

test_generation_parser_refuses_ambiguous_status() {
  local name="fm-lab-generation-records-$$" generation status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "generation parser fixture provision failed"
  generation=$(jq -er '.generation' "$TRIPWIRES/$name.session-identity.json") \
    || fail "generation parser fixture has no recorded generation"
  FM_FAKE_HERDR_STATUS_EXTRA_RECORD=1 \
    run_with_fake fm_herdr_lab_running_generation "$name" "$generation" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "concatenated server-status records must be ambiguous"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "generation parser fixture cleanup failed"
  pass "fm-herdr-lab: server generation accepts exactly one machine-readable status document"
}

test_generation_parser_requires_server_generation() {
  local name="fm-lab-generation-required-$$" generation status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "generation-required fixture provision failed"
  generation=$(jq -er '.generation' "$TRIPWIRES/$name.session-identity.json") \
    || fail "generation-required fixture has no recorded generation"
  FM_FAKE_HERDR_STATUS_OMIT_GENERATION=1 \
    run_with_fake fm_herdr_lab_running_generation "$name" "$generation" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server status without a generation must fail closed"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "generation-required fixture cleanup failed"
  pass "fm-herdr-lab: server status requires the authoritative generation contract"
}

test_bootstrap_revalidates_before_workspace_mutation() {
  local name="fm-lab-bootstrap-revalidate-$$" socket_dir marker status=0 saved server_pid replacement_generation
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "bootstrap revalidation fixture provision failed"
  socket_dir="$FAKE_STATE/sessions/$name"
  marker="$FAKE_STATE/$name.recreated"
  replacement_generation=00000000-0000-4000-8000-dddddddddddd
  saved=$(declare -f fm_herdr_lab_cli)
  eval "$(declare -f fm_herdr_lab_cli | sed '1s/fm_herdr_lab_cli/fm_herdr_lab_cli_original/')"
  fm_herdr_lab_cli() {
    local out
    if [ "${2:-} ${3:-}" = "pane list" ] && [ ! -f "$marker" ]; then
      out=$(fm_herdr_lab_cli_original "$@") || return 1
      printf '%s\n' "$replacement_generation" > "$FAKE_STATE/$name.generation"
      : > "$marker"
      printf '%s\n' "$out"
      return 0
    fi
    fm_herdr_lab_cli_original "$@"
  }
  run_with_fake fm_herdr_lab_bootstrap_pane "$name" >/dev/null 2>&1 || status=$?
  eval "$saved"
  unset -f fm_herdr_lab_cli_original
  expect_code 1 "$status" "bootstrap must refuse a replacement generation before workspace creation"
  ! grep -F "workspace create" "$FAKE_LOG" >/dev/null \
    || fail "bootstrap mutated a replacement session after its ownership snapshot"
  server_pid=$(cat "$FAKE_STATE/$name.server-pid")
  kill -TERM "$server_pid" 2>/dev/null || true
  rm -f "$TRIPWIRES/$name.fleet-state.json" "$TRIPWIRES/$name.session-identity.json" \
    "$FAKE_STATE/$name" "$FAKE_STATE/$name.server-pid" "$FAKE_STATE/$name.generation" "$marker"
  rm -rf "$socket_dir"
  pass "fm-herdr-lab: bootstrap revalidates generation immediately before mutation"
}

test_process_identity_is_locale_stable() {
  local pid utc eastern
  "$REAL_SLEEP" 30 &
  pid=$!
  utc=$(LC_ALL=C TZ=UTC fm_herdr_lab_process_start "$pid") || fail "could not read UTC process identity"
  eastern=$(LC_ALL=C TZ=America/New_York fm_herdr_lab_process_start "$pid") \
    || fail "could not read alternate-timezone process identity"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$utc" = "$eastern" ] || fail "process identity changed across timezone settings"
  pass "fm-herdr-lab: process identity is stable across caller locale and timezone"
}

test_real_proof_retains_cleanup_evidence() {
  grep -F "if [ \"\$CLEANED\" -eq 1 ] || [ -z \"\$SESSION\" ]; then" \
    "$ROOT/tests/fm-herdr-lab-bootstrap-e2e.test.sh" >/dev/null \
    || fail "real proof does not gate temporary-root removal on guarded cleanup"
  grep -F 'retaining cleanup evidence at %s' \
    "$ROOT/tests/fm-herdr-lab-bootstrap-e2e.test.sh" >/dev/null \
    || fail "real proof does not report retained cleanup evidence"
  pass "fm-herdr-lab: real proof retains and reports evidence after cleanup refusal"
}

test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_concurrent_run_waits_for_live_lifecycle_lock
test_dead_lifecycle_lock_is_reclaimed
test_stopped_session_refuses_foreign_restart_and_stop
test_stopped_receipt_rejects_precommit_generation_race
test_prepare_uses_guarded_owned_provisioning
test_provision_refuses_posthoc_foreign_session
test_provision_refuses_stale_bootstrap_evidence
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
test_stop_failure_is_propagated
test_bootstrap_state_failure_cleans_client_and_child
test_bootstrap_pending_zero_pids_cleanup
test_bootstrap_journals_client_before_pty_discovery
test_bootstrap_workspace_failure_retains_unresolved_pane
test_bootstrap_post_create_ownership_failure_retains_journal
test_bootstrap_record_retirement_retains_state_on_unexpected_entry
test_bootstrap_pane_is_scoped_owned_and_cleaned
test_bootstrap_pane_failure_is_bounded_and_cleans_client
test_bootstrap_cleanup_accepts_authoritative_pane_absence
test_bootstrap_pane_refuses_mismatched_ownership
test_bootstrap_pane_refuses_recreated_named_session
test_identity_parser_refuses_concatenated_records
test_generation_parser_refuses_ambiguous_status
test_generation_parser_requires_server_generation
test_bootstrap_revalidates_before_workspace_mutation
test_process_identity_is_locale_stable
test_real_proof_retains_cleanup_evidence
