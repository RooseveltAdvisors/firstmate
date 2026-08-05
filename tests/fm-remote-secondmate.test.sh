#!/usr/bin/env bash
# Hermetic Stage 1 remote-Secondmate transport checks.
# A fake ssh binary records argv and never contacts a host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-ssh-lib.sh
. "$ROOT/bin/fm-ssh-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SSH_LOG="$TMP_ROOT/ssh.log"
SSH_INPUT="$TMP_ROOT/ssh.input"
STATUS_REPLY="$TMP_ROOT/status.reply"
SENTINEL="$TMP_ROOT/injected"
CONFIG_EVENTS="$TMP_ROOT/config.events"
CONFIG_ENTERED="$TMP_ROOT/config.entered"
CONFIG_RELEASE="$TMP_ROOT/config.release"

cat >"$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
set -u
: >>"$FM_TEST_SSH_LOG"
last=
for arg in "$@"; do
  printf '%s\n' "$arg" >>"$FM_TEST_SSH_LOG"
  last=$arg
done
case "${FM_TEST_SSH_MODE:-ok}" in
  ok) exit 0 ;;
  capture) cat >"$FM_TEST_SSH_INPUT"; exit 0 ;;
  config)
    case "$last" in
      *--remote-receive*) cat >"$FM_TEST_SSH_INPUT"; printf '%s\n' 'config-reread-pointer: /srv/firstmate-housing/state/.fm-inherited-config-reread.1' ;;
    esac
    exit 0
    ;;
  config-lock)
    case "$last" in
      *--remote-receive*)
        cat >/dev/null
        printf 'receive\n' >>"$FM_TEST_CONFIG_EVENTS"
        if mkdir "$FM_TEST_CONFIG_ENTERED" 2>/dev/null; then
          while [ ! -f "$FM_TEST_CONFIG_RELEASE" ]; do sleep 0.02; done
        fi
        ;;
    esac
    exit 0
    ;;
  exec) bash -c "$last" ;;
  state) printf '%s\n' 'state: working · source: pane · remote agent busy' ;;
  status) cat "$FM_TEST_SSH_STATUS" ;;
  tick-busy|tick-idle)
    case "$last" in
      *--remote-status*) [ ! -f "$FM_TEST_SSH_STATUS" ] || cat "$FM_TEST_SSH_STATUS" ;;
      *--remote-herdr-state*)
        if [ "$FM_TEST_SSH_MODE" = tick-busy ]; then
          printf '%s\n' busy
        else
          printf '%s\n' idle
        fi
        ;;
      *) [ ! -f "$FM_TEST_SSH_STATUS" ] || cat "$FM_TEST_SSH_STATUS" ;;
    esac
    ;;
  fail) printf '%s\n' 'secret remote diagnostic' >&2; exit 1 ;;
  unreachable) printf '%s\n' 'private key path and host-key detail' >&2; exit 255 ;;
  sleep) sleep 3 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/ssh"

export FM_SSH_BIN="$FAKEBIN/ssh"
export FM_TEST_SSH_LOG="$SSH_LOG"
export FM_TEST_SSH_INPUT="$SSH_INPUT"
export FM_TEST_SSH_STATUS="$STATUS_REPLY"
export FM_TEST_CONFIG_EVENTS="$CONFIG_EVENTS"
export FM_TEST_CONFIG_ENTERED="$CONFIG_ENTERED"
export FM_TEST_CONFIG_RELEASE="$CONFIG_RELEASE"

cat >"$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pane get') printf '%s\n' '{"result":{"pane":{"pane_id":"workspace:pane"}}}' ;;
  'agent get') printf '%s\n' "{\"result\":{\"agent\":{\"agent_status\":\"${FM_TEST_HERDR_STATE:-working}\"}}}" ;;
  'pane read') printf '%s\n' "${FM_TEST_HERDR_PANE:-idle prompt}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

test_registry_and_input_boundaries() {
  local registry="$TMP_ROOT/secondmates.md"
  cat >"$registry" <<'EOF'
- local-one - Local route (home: /srv/local-one; scope: local work; projects: app; added 2026-08-05)
- housing-watch - Housing route (home: /srv/firstmate-housing; host: dev; scope: housing watch; projects: housing; added 2026-08-05)
EOF
  [ "$(fm_secondmate_registry_field "$registry" local-one home)" = /srv/local-one ] || fail "local registry parsing changed"
  ! fm_secondmate_registry_field "$registry" local-one host >/dev/null 2>&1 || fail "a local route acquired a host"
  [ "$(fm_secondmate_registry_field "$registry" housing-watch host)" = dev ] || fail "remote host was not parsed"
  [ "$(fm_secondmate_registry_field "$registry" housing-watch home)" = /srv/firstmate-housing ] || fail "remote home was not parsed"
  for host in 'user@dev' '-oProxyCommand=bad' 'dev;touch-x'; do
    ! fm_remote_host_valid "$host" || fail "unsafe host accepted: $host"
  done
  for path in relative '/srv/../root' '/srv/with space' '/'; do
    ! fm_remote_path_valid "$path" || fail "unsafe remote path accepted: $path"
  done
  pass "remote registry: optional host preserves local parsing and rejects unsafe identities"
}

test_strict_ssh_and_quoting() {
  local out rc
  : >"$SSH_LOG"
  export FM_TEST_SSH_MODE=exec
  out=$(fm_ssh_run dev printf '%s' "safe'; touch '$SENTINEL'; :") || fail "quoted argv call failed"
  [ "$out" = "safe'; touch '$SENTINEL'; :" ] || fail "remote argv bytes changed"
  [ ! -e "$SENTINEL" ] || fail "remote argv escaped shell quoting"
  for option in BatchMode=yes StrictHostKeyChecking=yes ForwardAgent=no ClearAllForwardings=yes PasswordAuthentication=no; do
    grep -Fx -- "$option" "$SSH_LOG" >/dev/null || fail "missing strict SSH option $option"
  done
  # shellcheck disable=SC2016 # This literal must expand only on the remote side.
  grep -F 'test "$(id -u)" -ne 0 && exec' "$SSH_LOG" >/dev/null || fail "remote root refusal is missing"
  FM_TEST_SSH_MODE=unreachable fm_ssh_run dev true >/dev/null 2>"$TMP_ROOT/error"; rc=$?
  [ "$rc" -eq "$FM_SSH_UNREACHABLE_RC" ] || fail "SSH/host-key loss was not unreachable: $rc"
  [ ! -s "$TMP_ROOT/error" ] || fail "SSH diagnostics were not redacted"
  FM_TEST_SSH_MODE=fail fm_ssh_run dev true >/dev/null 2>"$TMP_ROOT/error"; rc=$?
  [ "$rc" -eq "$FM_SSH_UNREADABLE_RC" ] || fail "remote command failure was not unreadable: $rc"
  FM_TEST_SSH_MODE=sleep FM_SSH_OPERATION_TIMEOUT=1 fm_ssh_run dev true >/dev/null; rc=$?
  [ "$rc" -eq "$FM_SSH_UNREACHABLE_RC" ] || fail "bounded timeout was not unreachable: $rc"
  pass "SSH transport: strict options, safe argv, redaction, failure classes, and whole-operation timeout"
}

make_parent() {
  local home="$TMP_ROOT/parent"
  mkdir -p "$home/state" "$home/data" "$home/config"
  cat >"$home/state/housing-watch.meta" <<'EOF'
window=pilot:workspace:pane
worktree=/srv/firstmate-housing
project=/srv/firstmate-housing
harness=codex
kind=secondmate
mode=secondmate
yolo=off
backend=herdr
home=/srv/firstmate-housing
EOF
  cat >"$home/data/secondmates.md" <<'EOF'
- housing-watch - Housing route (home: /srv/firstmate-housing; host: dev; scope: housing watch; projects: housing; added 2026-08-05)
EOF
  printf '%s\n' "$home"
}

test_send_state_and_pending_reply() {
  local home=$1 corr rec ambiguous_rec out rc before after pending_before pending_after
  FM_TEST_SSH_MODE=ok FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" fm-housing-watch "inspect housing" >/dev/null 2>"$TMP_ROOT/send.err" \
    || fail "marked remote send was not acknowledged"
  rec=$(find "$home/state/pending-replies" -type f ! -name '.*' | head -1)
  [ -f "$rec" ] || fail "remote send did not create the parent expectation"
  grep -q '^delivered_epoch=.' "$rec" || fail "remote send acknowledgement was not committed"
  grep -F "$FM_FROMFIRST_MARK" "$SSH_LOG" >/dev/null || fail "remote send lost the from-firstmate marker"
  grep -F 'inspect housing' "$SSH_LOG" >/dev/null || fail "remote send lost its request body"

  pending_before=$(find "$home/state/pending-replies" -type f ! -name '.*' | wc -l | tr -d ' ')
  FM_PENDING_REPLY_GRACE_SECS=0 FM_TEST_SSH_MODE=unreachable FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" fm-housing-watch "undeliverable request" >/dev/null 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "unreachable remote send was acknowledged"
  pending_after=$(find "$home/state/pending-replies" -type f ! -name '.*' | wc -l | tr -d ' ')
  [ "$pending_after" -eq $((pending_before + 1)) ] || fail "ambiguous remote send lost its pending expectation"
  ambiguous_rec=$(find "$home/state/pending-replies" -type f ! -name '.*' -exec grep -l 'undeliverable request' {} + | head -1)
  [ -f "$ambiguous_rec" ] || fail "ambiguous remote send record is missing"
  corr=$(sed -n 's/^corr_id=//p' "$ambiguous_rec")
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  fm_pending_reply_reconcile_delivery "$home/state" "$corr" \
    || fail "ambiguous remote send did not enter delivery-unknown reconciliation"
  [ "$(fm_pending_reply_get "$ambiguous_rec" phase)" = delivery_unknown ] \
    || fail "ambiguous remote send was not retained as delivery_unknown"
  printf 'done: [corr=%s] delayed ambiguous delivery reply\n' "$corr" >"$STATUS_REPLY"
  FM_TEST_SSH_MODE=status fm_pending_reply_tick "$home/state"
  [ "$(fm_pending_reply_get "$ambiguous_rec" phase)" = resolved ] \
    || fail "late reply did not reconcile ambiguous remote delivery"

  out=$(FM_TEST_SSH_MODE=tick-busy FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-crew-state.sh" housing-watch)
  case "$out" in 'state: working'*'source: pane'*) ;; *) fail "remote current-state command was not reused: $out" ;; esac
  grep -F -- '--remote-herdr-state' "$SSH_LOG" >/dev/null || fail "remote current state still depended on self metadata"
  out=$(FM_TEST_SSH_MODE=unreachable FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-crew-state.sh" housing-watch)
  case "$out" in 'state: unreachable'*'source: remote-host'*) ;; *) fail "SSH loss was not explicit unreachable: $out" ;; esac
  out=$(FM_TEST_SSH_MODE=fail FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-crew-state.sh" housing-watch)
  case "$out" in 'state: unknown'*'remote state unreadable'*) ;; *) fail "unreadable remote state was misclassified: $out" ;; esac

  corr=$(sed -n 's/^corr_id=//p' "$rec")
  printf 'done: [corr=%s] housing watch complete\n' "$corr" >"$STATUS_REPLY"
  FM_TEST_SSH_MODE=status fm_pending_reply_tick "$home/state"
  [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] || fail "late remote reply did not reconcile idempotently"
  FM_TEST_SSH_MODE=status fm_pending_reply_tick "$home/state"
  [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] || fail "late reply reconciliation was not idempotent"

  FM_TEST_SSH_MODE=ok FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" fm-housing-watch "second request" >/dev/null 2>/dev/null || fail "second remote send failed"
  for rec in "$home/state/pending-replies"/*; do
    [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] || break
  done
  before=$(fm_pending_reply_get "$rec" phase)
  FM_TEST_SSH_MODE=fail fm_pending_reply_tick "$home/state"
  after=$(fm_pending_reply_get "$rec" phase)
  [ "$before" = "$after" ] || fail "unreadable remote status advanced a pending expectation"
  [ "$(fm_pending_reply_get "$rec" reachability)" = unreadable ] || fail "pending reply lacks unreadable classification"
  : >"$SSH_LOG"
  FM_TEST_SSH_MODE=unreachable fm_pending_reply_tick "$home/state"
  after=$(fm_pending_reply_get "$rec" phase)
  [ "$before" = "$after" ] || fail "unreachable remote cleared or advanced a pending expectation"
  [ "$(fm_pending_reply_get "$rec" reachability)" = unreachable ] || fail "pending reply lacks unreachable classification"
  [ "$(grep -c . "$SSH_LOG")" -gt 0 ] || fail "remote status was not attempted"

  export FM_PENDING_REPLY_GRACE_SECS=0
  FM_TEST_SSH_MODE=ok FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" fm-housing-watch "turn-state request" >/dev/null 2>/dev/null \
    || fail "turn-state remote send failed"
  rec=$(find "$home/state/pending-replies" -type f ! -name '.*' -exec grep -l 'turn-state request' {} + | head -1)
  rm -f "$STATUS_REPLY"
  FM_TEST_SSH_MODE=tick-busy fm_pending_reply_tick "$home/state"
  [ "$(fm_pending_reply_get "$rec" turn_seen_busy)" = 1 ] || fail "remote working state was not observed as busy"
  FM_TEST_SSH_MODE=tick-idle fm_pending_reply_tick "$home/state"
  [ "$(fm_pending_reply_get "$rec" phase)" = recovery_sent ] || fail "remote idle state did not trigger recovery"
  FM_TEST_SSH_MODE=tick-busy fm_pending_reply_tick "$home/state"
  FM_TEST_SSH_MODE=tick-idle fm_pending_reply_tick "$home/state"
  [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] || fail "remote recovery turn could not escalate"
  pass "remote routing: acknowledged marked send, state classes, and idempotent late-reply reconciliation"
}

test_remote_status_read_distinguishes_absent() {
  local home="$TMP_ROOT/status-home" out rc
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-crew-state.sh" --remote-status housing-watch) \
    || fail "absent remote status was not readable empty history"
  [ -z "$out" ] || fail "absent remote status emitted content"
  printf 'working: present\n' >"$home/state/housing-watch.status"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-crew-state.sh" --remote-status housing-watch) \
    || fail "regular remote status was unreadable"
  [ "$out" = 'working: present' ] || fail "remote status bytes changed"
  rm -f "$home/state/housing-watch.status"
  ln -s "$home/elsewhere" "$home/state/housing-watch.status"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-crew-state.sh" \
    --remote-status housing-watch >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe remote status was accepted as absent"
  pass "remote status: absent history is empty, unsafe files unreadable"
}

test_remote_state_reads_recorded_target_without_meta() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" FM_TEST_HERDR_STATE=working FM_HOME="$TMP_ROOT/no-meta" \
    FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-crew-state.sh" --remote-herdr-state pilot:workspace:pane codex)
  [ "$out" = busy ] || fail "direct remote target did not report native busy state: $out"
  out=$(PATH="$FAKEBIN:$PATH" FM_TEST_HERDR_STATE=idle FM_HOME="$TMP_ROOT/no-meta" \
    FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-crew-state.sh" --remote-herdr-state pilot:workspace:pane codex)
  [ "$out" = idle ] || fail "direct remote target did not report verified idle state: $out"
  pass "remote current state: recorded Herdr target needs no remote self metadata"
}

test_config_push_uses_allowlisted_archive() {
  local home=$1 listing
  printf 'codex\n' >"$home/config/crew-harness"
  printf 'must-not-leave\n' >"$home/config/private-secret"
  : >"$SSH_LOG"
  FM_TEST_SSH_MODE=config FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-config-push.sh" >"$TMP_ROOT/config.out" 2>"$TMP_ROOT/config.err" \
    || fail "remote config push was not acknowledged"
  listing=$(tar -tf "$SSH_INPUT") || fail "config push did not send an archive"
  case "$listing" in *config/crew-harness*) ;; *) fail "allowlisted config was not pushed" ;; esac
  case "$listing" in *private-secret*) fail "non-allowlisted config entered the remote archive" ;; esac
  grep -F '/srv/firstmate-housing/bin/fm-config-push.sh' "$SSH_LOG" >/dev/null \
    || fail "config push did not reuse the remote Firstmate command"
  grep -F -- '--remote-receive' "$SSH_LOG" >/dev/null || fail "config push did not select receive mode"
  grep -F 'CONFIG_REREAD: /srv/firstmate-housing/state/.fm-inherited-config-reread.1' "$SSH_LOG" >/dev/null \
    || fail "parent did not route the remote reread pointer"
  grep -F "$FM_FROMFIRST_MARK" "$SSH_LOG" >/dev/null || fail "remote reread pointer was not marked at the parent"
  grep -F -- '--remote-reread-sent' "$SSH_LOG" >/dev/null || fail "remote reread delivery was not acknowledged"
  pass "remote config push: existing owner receives only the inherited allowlist"
}

test_config_push_serializes_remote_route() {
  local home=$1 first second count i=0
  rm -rf "$CONFIG_ENTERED"
  rm -f "$CONFIG_EVENTS" "$CONFIG_RELEASE"
  FM_TEST_SSH_MODE=config-lock FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-config-push.sh" >/dev/null 2>/dev/null &
  first=$!
  while [ ! -d "$CONFIG_ENTERED" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
  [ -d "$CONFIG_ENTERED" ] || fail "first remote config transaction did not reach receive"
  FM_TEST_SSH_MODE=config-lock FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-config-push.sh" >/dev/null 2>/dev/null &
  second=$!
  sleep 0.2
  count=$(wc -l <"$CONFIG_EVENTS" | tr -d ' ')
  [ "$count" = 1 ] || fail "concurrent remote config transaction bypassed the parent route lock"
  : >"$CONFIG_RELEASE"
  wait "$first" || fail "first serialized remote config push failed"
  wait "$second" || fail "second serialized remote config push failed"
  [ "$(wc -l <"$CONFIG_EVENTS" | tr -d ' ')" = 2 ] || fail "serialized remote config transaction did not resume"
  pass "remote config push: parent route lock preserves generation order"
}

test_config_receive_applies_owner_and_rejects_extra_paths() {
  local remote="$TMP_ROOT/remote-home" source="$TMP_ROOT/receive-source" archive="$TMP_ROOT/receive.tar" out pointer rc
  mkdir -p "$remote/data" "$remote/state" "$remote/config" "$remote/projects" "$source/data" "$source/config"
  printf '%s\n' housing-watch >"$remote/.fm-secondmate-home"
  cat >"$source/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and read-only in secondmate homes.
It must not be edited there; discoveries return to the main firstmate through marked status or a document pointer.
EOF
  printf 'codex\n' >"$source/config/crew-harness"
  tar -cf "$archive" -C "$source" .
  out=$(FM_HOME="$remote" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-config-push.sh" \
    --remote-receive housing-watch <"$archive" 2>"$TMP_ROOT/receive.err") \
    || fail "remote receive did not apply through the inheritance owner"
  cmp -s "$source/data/captain-shared.md" "$remote/data/captain-shared.md" \
    || fail "remote receive did not preserve inherited bytes"
  pointer=$(printf '%s\n' "$out" | sed -n 's/^config-reread-pointer: //p')
  [ -f "$pointer" ] && [ -f "$pointer.pending" ] || fail "remote receive did not retain a parent-routed reread pointer"
  FM_HOME="$remote" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-config-push.sh" \
    --remote-reread-sent housing-watch "$pointer" >/dev/null \
    || fail "remote receive did not accept parent delivery acknowledgement"
  [ ! -e "$pointer.pending" ] || fail "remote reread acknowledgement did not clear pending delivery"
  printf 'not allowed\n' >"$source/extra"
  tar -cf "$archive" -C "$source" extra
  FM_HOME="$remote" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-config-push.sh" \
    --remote-receive housing-watch <"$archive" >/dev/null 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "remote receive accepted a non-allowlisted archive path"
  [ ! -e "$remote/extra" ] || fail "rejected archive escaped into the remote home"
  pass "remote config receive: existing inheritance owner applies safe bytes and rejects extra paths"
}

test_registry_and_input_boundaries
test_strict_ssh_and_quoting
PARENT=$(make_parent)
test_send_state_and_pending_reply "$PARENT"
test_remote_status_read_distinguishes_absent
test_remote_state_reads_recorded_target_without_meta
test_config_push_uses_allowlisted_archive "$PARENT"
test_config_push_serializes_remote_route "$PARENT"
test_config_receive_applies_owner_and_rejects_extra_paths
