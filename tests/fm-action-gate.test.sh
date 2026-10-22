#!/usr/bin/env bash
# Public-interface action gate regressions without signing keys or brake state.
# Root-store cases use sudo only inside this suite's disposable installation.
# FM_ACTION_GATE_PRIVILEGED=1 requires those cases instead of capability-skipping.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP=$(fm_test_tmproot fm-action-gate-test)
INSTALL="$TMP/install"
LAB="$TMP/lab"
SOURCE=${FM_ACTION_GATE_TEST_SOURCE:-$ROOT}
mkdir -p "$INSTALL/bin" "$LAB/state"
for enforcement in fm-action-gate.sh fm-action-gate-lib.sh fm-gate-refuse-lib.sh; do
  cp "$SOURCE/bin/$enforcement" "$INSTALL/bin/$enforcement"
done
mkdir "$INSTALL/bin/runtime-bin"
cp "$(command -v jq)" "$INSTALL/bin/runtime-bin/jq"
chmod a-w "$INSTALL/bin/runtime-bin/jq" "$INSTALL/bin/runtime-bin"
git -C "$INSTALL" init -q
git -C "$INSTALL" add bin
git -C "$INSTALL" -c user.name=Test -c user.email=test@example.invalid commit -qm baseline
chmod a-w "$INSTALL"/bin/*
ACTION_GATE="$INSTALL/bin/fm-action-gate.sh"
call() { env -u FM_RUNNER_UNTRUSTED FM_HOME="$LAB" bash "$ACTION_GATE" "$@"; }
refuse() {
  local output
  if output=$(call "$@" 2>&1); then fail "expected refusal: $*"; fi
  assert_contains "$output" DENY "refusal should name DENY"
  printf '%s\n' "$output"
}
last_evidence() { tail -n 1 "$LAB/state/evidence/actions/action-ledger.jsonl"; }
request() {
  local file=$1 kind=$2 origin=$3
  shift 3
  jq -nc --arg kind "$kind" --arg origin "$origin" --args \
    '{provenance:{kind:$kind,origin_action_class:$origin},argv:$ARGS.positional}' -- "$@" > "$file"
}

# No keypair, authority.pem, control record, admission lock or grant store exists.
out=$(call execute mail_draft synthetic-target synthetic-task '' draft-json \
  '{"to":"synthetic@example.invalid","subject":"Synthetic","body":"Draft only"}')
assert_contains "$out" '"operation": "mail_draft"' 'draft must execute without provisioning'
pass 'step1(a): mail_draft admitted with no keypair or brake.json'

for action in mail_send send; do
  out=$(refuse execute "$action" synthetic-target synthetic-task '' /usr/bin/printf MAIL_EXECUTED)
  assert_contains "$out" 'real mail send is strictly prohibited' 'mail policy must fire directly'
  [[ "$out" != *MAIL_EXECUTED* ]] || fail 'mail command ran'
done
last_evidence | jq -e '.decision=="DENY"' >/dev/null || fail 'mail denial was not recorded'
pass 'step1(b): mail_send and send remain hard denied'

for action in booking charging prod_deploy deploy; do
  status=0
  out=$(call check "$action" synthetic-target synthetic-task 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "missing $action grant should exit 2, got $status"
  assert_contains "$out" HUMAN_REVIEW 'missing grant must require human review'
  if out=$(call execute "$action" synthetic-target synthetic-task '' /usr/bin/printf NO_GRANT_EXECUTED 2>&1); then
    fail 'missing grant must refuse execution'
  fi
  assert_contains "$out" HUMAN_REVIEW 'missing execution grant must require human review'
  [[ "$out" != *NO_GRANT_EXECUTED* ]] || fail 'ungranted command ran'
done
pass 'missing grants route to HUMAN_REVIEW and never execute'

for enforcement in fm-action-gate.sh fm-action-gate-lib.sh fm-gate-refuse-lib.sh; do
  chmod u+w "$INSTALL/bin/$enforcement"
  out=$(refuse check draft synthetic-target synthetic-task)
  assert_contains "$out" 'enforcement tamper check' "writable $enforcement must refuse"
  chmod a-w "$INSTALL/bin/$enforcement"
done
cp "$INSTALL/bin/fm-action-gate-lib.sh" "$TMP/original-lib"
chmod u+w "$INSTALL/bin/fm-action-gate-lib.sh"
printf '\nexit 97\n' >> "$INSTALL/bin/fm-action-gate-lib.sh"
chmod a-w "$INSTALL/bin/fm-action-gate-lib.sh"
out=$(refuse check draft synthetic-target synthetic-task)
assert_contains "$out" 'content differs from committed baseline' 'changed library must refuse before sourcing'
chmod u+w "$INSTALL/bin/fm-action-gate-lib.sh"
cp "$TMP/original-lib" "$INSTALL/bin/fm-action-gate-lib.sh"
chmod a-w "$INSTALL/bin/fm-action-gate-lib.sh"
out=$(call check draft synthetic-target synthetic-task)
assert_contains "$out" ALLOW 'restored enforcement must evaluate'
pass 'step1(d): writable or altered enforcement denied; restored enforcement evaluates'

# Preserve the distinct-owner Git baseline check used by root installations.
out=$(env -u GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_SYSTEM=/dev/null GIT_TEST_ASSUME_DIFFERENT_OWNER=true FM_HOME="$LAB" \
  bash "$ACTION_GATE" check draft synthetic-target synthetic-task)
assert_contains "$out" ALLOW 'intact protected checkout with different Git owner must evaluate'
pass 'protected checkout remains usable with a different Git owner'

mv "$INSTALL/bin/fm-gate-refuse-lib.sh" "$TMP/refuse-lib"
ln -s "$TMP/refuse-lib" "$INSTALL/bin/fm-gate-refuse-lib.sh"
refuse check draft synthetic-target synthetic-task >/dev/null
rm "$INSTALL/bin/fm-gate-refuse-lib.sh"
mv "$TMP/refuse-lib" "$INSTALL/bin/fm-gate-refuse-lib.sh"
pass 'symlinked enforcement denied'

for command in '/bin/sh' '/usr/bin/printf'; do
  out=$(refuse execute mail_draft synthetic-target synthetic-task '' "$command" DRAFT_EXTERNAL_EXECUTED)
  [[ "$out" != *DRAFT_EXTERNAL_EXECUTED* ]] || fail 'draft invoked external command'
done
refuse execute draft synthetic-target synthetic-task '' >/dev/null
refuse execute draft synthetic-target synthetic-task '' draft-json '{"to":"x","subject":"x","body":"x","command":"curl"}' >/dev/null
pass 'drafts remain restricted to the built-in typed renderer'

mkdir -p "$LAB/state/evidence.saved"
mv "$LAB/state/evidence/actions" "$LAB/state/evidence.saved/actions"
: > "$LAB/state/evidence/actions"
refuse execute draft synthetic-target synthetic-task '' draft-json '{"to":"x","subject":"x","body":"x"}' >/dev/null
rm "$LAB/state/evidence/actions"
mv "$LAB/state/evidence.saved/actions" "$LAB/state/evidence/actions"
pass 'evidence failure still denies execution'

out=$(env FM_HOME="$LAB" NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS='' bash "$ACTION_GATE" check draft synthetic-target synthetic-task 2>&1 || true)
assert_contains "$out" 'no-mistakes gate agent must not drive the fleet' 'gate context must still refuse'
pass 'no-mistakes fleet boundary preserved'

STORE=$(call grant-store)
mkdir -p "$STORE"
request "$TMP/request.json" trusted booking /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n'
jq -nc --slurpfile request "$TMP/request.json" \
  '{action_class:"booking",target:"synthetic-target",task_id:"synthetic-task",expires_at:"2030-01-01T00:00:00Z",approval_reference:"worker-forged",used_at:null,request:$request[0]}' > "$STORE/worker-forged.json"
chmod a-w "$STORE/worker-forged.json" "$STORE" "$(dirname "$STORE")" "$(dirname "$(dirname "$STORE")")"
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/worker-forged.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n')
[[ "$out" != *BOUND_BOOKING_EXECUTED* ]] || fail 'worker-owned plain grant executed'
pass 'worker-owned plain grant denied even with read-only mode bits'
chmod u+w "$STORE" "$(dirname "$STORE")" "$(dirname "$(dirname "$STORE")")"

if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
  if [ "${FM_ACTION_GATE_PRIVILEGED:-0}" = 1 ]; then
    fail 'root-store integration requires noninteractive sudo inside the disposable fixture'
  fi
  printf 'skip: root-store integration requires noninteractive sudo; set FM_ACTION_GATE_PRIVILEGED=1 to require it\n'
  exit 0
fi

# This is real ownership, not a mocked stat/signature verifier. Restore fixture
# ownership on exit so the shared test cleanup can remove only its own files.
fixture_owner="$(id -u):$(id -g)"
restore_fixture() { sudo -n chown -R "$fixture_owner" "$INSTALL"; }
trap 'restore_fixture; fm_test_cleanup' EXIT
sudo -n chown -R 0:0 "$INSTALL/bin" "$INSTALL/.action-control"
sudo -n chmod -R go-w "$INSTALL/bin" "$INSTALL/.action-control"
admin() { sudo -n env FM_HOME="$LAB" bash "$ACTION_GATE" "$@"; }
mint() {
  local name=$1 class=$2 request_file=$3
  admin mint-grant "$STORE/$name.json" "$class" synthetic-target synthetic-task \
    2030-01-01T00:00:00Z "$name" "$request_file"
}

for action in booking charging prod_deploy deploy; do
  request "$TMP/request-$action.json" trusted "$action" /usr/bin/printf "BOUND_${action}_EXECUTED"
  mint "valid-$action" "$action" "$TMP/request-$action.json"
  out=$(call execute "$action" synthetic-target synthetic-task "$STORE/valid-$action.json" /usr/bin/printf "BOUND_${action}_EXECUTED")
  assert_contains "$out" "BOUND_${action}_EXECUTED" 'plain root-owned grant must execute'
  refuse execute "$action" synthetic-target synthetic-task "$STORE/valid-$action.json" /usr/bin/printf "BOUND_${action}_EXECUTED" >/dev/null
done
pass 'step1(c): plain protected grants admit booking, charging and deploy once, without keys or brake state'

# Neither malformed JSON nor writable authority is an empty/missing grant.
printf '{' > "$TMP/malformed.json"
sudo -n cp "$TMP/malformed.json" "$STORE/malformed.json"
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/malformed.json" /usr/bin/printf MALFORMED_EXECUTED)
assert_contains "$out" 'unprotected or malformed JSON' 'malformed grant must hard deny'
[[ "$out" != *MALFORMED_EXECUTED* ]] || fail 'malformed grant executed'
mint writable booking "$TMP/request.json"
sudo -n chmod 666 "$STORE/writable.json"
refuse execute booking synthetic-target synthetic-task "$STORE/writable.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n' >/dev/null
pass 'malformed and worker-writable grants hard deny'

mint mismatch booking "$TMP/request.json"
refuse execute booking wrong-target synthetic-task "$STORE/mismatch.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n' >/dev/null
refuse execute booking synthetic-target wrong-task "$STORE/mismatch.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n' >/dev/null
refuse execute charging synthetic-target synthetic-task "$STORE/mismatch.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n' >/dev/null
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/mismatch.json" /usr/bin/printf UNAPPROVED)
assert_contains "$out" 'command differs from approved payload' 'grant must still bind exact argv'
pass 'class, target, task and exact payload binding preserved'

request "$TMP/forwarded.json" untrusted-forwarded mail_send /usr/bin/printf RELABELED_MAIL_EXECUTED
mint forwarded booking "$TMP/forwarded.json"
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/forwarded.json" /usr/bin/printf RELABELED_MAIL_EXECUTED)
assert_contains "$out" 'provenance origin' 'mail_send cannot execute under a booking label'
[[ "$out" != *RELABELED_MAIL_EXECUTED* ]] || fail 'relabeled mail executed'
pass 'forwarded mail provenance remains bound to the approved action'

admin mint-grant "$STORE/expired.json" booking synthetic-target synthetic-task \
  2020-01-01T00:00:00Z expired "$TMP/request.json"
out=$(refuse check booking synthetic-target synthetic-task "$STORE/expired.json")
assert_contains "$out" 'grant has expired' 'expiry remains enforced'
pass 'plain grants still expire'

request "$TMP/concurrent.json" trusted booking /usr/bin/printf CONCURRENT_EXECUTED
mint concurrent booking "$TMP/concurrent.json"
pids=()
for i in 1 2 3 4; do
  call execute booking synthetic-target synthetic-task "$STORE/concurrent.json" /usr/bin/printf CONCURRENT_EXECUTED > "$TMP/concurrent-$i" 2>&1 &
  pids+=("$!")
done
success=0
for pid in "${pids[@]}"; do
  if wait "$pid"; then success=$((success+1)); fi
done
[ "$success" -eq 1 ] || fail "expected one concurrent execution, got $success"
pass 'atomic consumption admits only one concurrent execution'
printf 'ok: all Step 1 action gate regressions passed with real root-owned grants\n'
