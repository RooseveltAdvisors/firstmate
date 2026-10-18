#!/usr/bin/env bash
# Public-interface regressions for the action gate: tampering, authenticated
# grants, independent brake, provenance, payload classes and one-use admission.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP=$(fm_test_tmproot fm-action-gate-test)
INSTALL="$TMP/install"
LAB="$TMP/lab"
KEY="$TMP/administrator.pem"
mkdir -p "$INSTALL/bin" "$LAB/state/grants"
for enforcement in fm-action-gate.sh fm-action-gate-lib.sh fm-gate-refuse-lib.sh; do
  cp "$ROOT/bin/$enforcement" "$INSTALL/bin/$enforcement"
done
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY" 2>/dev/null
openssl pkey -in "$KEY" -pubout -out "$INSTALL/bin/fm-action-authority.pem" 2>/dev/null
chmod 600 "$KEY"
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
request() {
  local file=$1 kind=$2 origin=$3
  shift 3
  jq -nc --arg kind "$kind" --arg origin "$origin" --args \
    '{provenance:{kind:$kind,origin_action_class:$origin},argv:$ARGS.positional}' -- "$@" > "$file"
}
mint() {
  local name=$1 class=$2 request_file=$3
  call mint-grant "$STORE/$name.json" "$class" synthetic-target synthetic-task \
    2030-01-01T00:00:00Z "$name" "$request_file" "$KEY"
}

call init-control "$KEY" initial-control
control=$(find "$INSTALL/.action-control" -name brake.json -type f)
STORE="$(dirname "$control")/grants"
out=$(call check mail_draft synthetic-target synthetic-task)
assert_contains "$out" ALLOW "provisioned clear state should admit draft checks"
pass "signed control provisioning permits normal checks"

# #7: all three files are independently tested, with unchanged restored controls.
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
assert_contains "$out" 'content differs from committed baseline' "changed library must refuse before source"
chmod u+w "$INSTALL/bin/fm-action-gate-lib.sh"
cp "$TMP/original-lib" "$INSTALL/bin/fm-action-gate-lib.sh"
chmod a-w "$INSTALL/bin/fm-action-gate-lib.sh"
out=$(call check draft synthetic-target synthetic-task)
assert_contains "$out" ALLOW "restored enforcement must evaluate"
pass "#7 runtime guard refuses writable or altered enforcement and resumes after restore"

mv "$INSTALL/bin/fm-gate-refuse-lib.sh" "$TMP/refuse-lib"
ln -s "$TMP/refuse-lib" "$INSTALL/bin/fm-gate-refuse-lib.sh"
refuse check draft synthetic-target synthetic-task >/dev/null
rm "$INSTALL/bin/fm-gate-refuse-lib.sh"
mv "$TMP/refuse-lib" "$INSTALL/bin/fm-gate-refuse-lib.sh"
pass "symlinked enforcement cannot replace a pinned library"

# Original same-user forged authority is denied even with read-only enforcement.
jq -nc '{action_class:"booking",target:"synthetic-target",task_id:"synthetic-task",expires_at:"2030-01-01T00:00:00Z",approval_reference:"forged",used_at:null}' > "$STORE/forged.json"
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/forged.json" /usr/bin/printf FORGED_EXECUTED)
assert_contains "$out" 'unsigned or altered grant' "same-user forged grant must be denied"
[[ "$out" != *FORGED_EXECUTED* ]] || fail 'forged command ran'
pass "#7 same-user grant forgery denied without relying on grant-store write permissions"

mkdir "$TMP/fake-tools"
for tool in git jq openssl; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/fake-tools/$tool"
  chmod +x "$TMP/fake-tools/$tool"
done
if env PATH="$TMP/fake-tools:$PATH" FM_HOME="$LAB" /bin/bash "$ACTION_GATE" execute booking \
  synthetic-target synthetic-task "$STORE/forged.json" /usr/bin/printf FORGED_EXECUTED > "$TMP/path-attack" 2>&1; then
  fail "caller PATH must not replace signature or baseline verification"
fi
assert_contains "$(cat "$TMP/path-attack")" DENY "untrusted PATH must not grant authority"
pass "caller PATH cannot replace verifier tools"

# Valid command and one-time use, then parameter mismatches with fresh grants.
request "$TMP/request.json" trusted booking /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n'
mint valid booking "$TMP/request.json"
out=$(call execute booking synthetic-target synthetic-task "$STORE/valid.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n')
assert_contains "$out" BOUND_BOOKING_EXECUTED "exact signed command should execute"
refuse execute booking synthetic-target synthetic-task "$STORE/valid.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n' >/dev/null
pass "valid signed command executes once and replay refuses"

mint mismatch booking "$TMP/request.json"
refuse execute booking wrong-target synthetic-task "$STORE/mismatch.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n' >/dev/null
refuse execute booking synthetic-target wrong-task "$STORE/mismatch.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n' >/dev/null
refuse execute charging synthetic-target synthetic-task "$STORE/mismatch.json" /usr/bin/printf 'BOUND_BOOKING_EXECUTED\n' >/dev/null
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/mismatch.json" /usr/bin/printf UNAPPROVED)
assert_contains "$out" 'command differs from signed approved payload' "approved class cannot substitute argv"
pass "task, target, class and exact command remain bound"

call mint-grant "$STORE/expired.json" booking synthetic-target synthetic-task \
  2020-01-01T00:00:00Z expired "$TMP/request.json" "$KEY"
out=$(refuse check booking synthetic-target synthetic-task "$STORE/expired.json")
assert_contains "$out" 'grant has expired' "signed grants still expire"
if env FM_HOME="$LAB" FM_CAPTAIN_AUTH=1 bash "$ACTION_GATE" mint-grant "$STORE/env-forged.json" \
  booking synthetic-target synthetic-task 2030-01-01T00:00:00Z fake-authority "$TMP/request.json" > "$TMP/env-forged" 2>&1; then
  fail "captain environment flag must not replace the signing key"
fi
assert_contains "$(cat "$TMP/env-forged")" 'administrator signing key' "missing key must refuse"
pass "expiry and independent signing authority remain enforced"

# #3: signed provenance is checked at the effect boundary, not trusted from env.
request "$TMP/forwarded.json" untrusted-forwarded mail_send /usr/bin/printf RELABELED_MAIL_EXECUTED
mint forwarded booking "$TMP/forwarded.json"
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/forwarded.json" /usr/bin/printf RELABELED_MAIL_EXECUTED)
assert_contains "$out" 'provenance origin' "forwarded mail_send cannot execute as booking"
[[ "$out" != *RELABELED_MAIL_EXECUTED* ]] || fail 'relabeled mail ran'
pass "#3 forwarded mail_send relabeled booking denied before execution"

# Modifying signed provenance or argv cannot preserve a valid grant signature.
jq '.request.provenance.origin_action_class="booking"' "$STORE/forwarded.json" > "$STORE/edited.json"
refuse execute booking synthetic-target synthetic-task "$STORE/edited.json" /usr/bin/printf RELABELED_MAIL_EXECUTED >/dev/null
pass "caller cannot rewrite signed provenance"

# #2: no external program, interpreter, curl or empty command under a draft label.
cat > "$TMP/curl" <<'CURL'
#!/usr/bin/env bash
printf 'CURL_EXECUTED %s\n' "$*"
CURL
chmod +x "$TMP/curl"
out=$(refuse execute mail_draft synthetic-target synthetic-task '' "$TMP/curl" https://forbidden.invalid/synthetic)
assert_contains "$out" 'mail_draft accepts only draft-json' "draft cannot run curl"
[[ "$out" != *CURL_EXECUTED* ]] || fail 'draft executed curl'
refuse execute draft synthetic-target synthetic-task '' /bin/sh -c 'exit 99' >/dev/null
refuse execute draft synthetic-target synthetic-task '' >/dev/null
refuse execute draft synthetic-target synthetic-task '' draft-json '{"to":"x","subject":"x","body":"x","command":"curl"}' >/dev/null
out=$(call execute mail_draft synthetic-target synthetic-task '' draft-json '{"to":"synthetic@example.invalid","subject":"Synthetic","body":"Draft only"}')
assert_contains "$out" '"operation": "mail_draft"' "draft-json should produce only a draft record"
pass "#2 arbitrary curl denied; draft class renders only a typed draft"

# #16: a separate signing authority controls the brake; caller env is insufficient.
request "$TMP/queued.json" trusted booking /usr/bin/printf QUEUED_EXECUTED
mint queued booking "$TMP/queued.json"
refuse brake set "$TMP/missing-private-key" unauthenticated >/dev/null
call brake set "$KEY" human-stop
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/queued.json" /usr/bin/printf QUEUED_EXECUTED)
assert_contains "$out" 'human brake is active' "queued request must deny while stopped"
refuse execute mail_draft synthetic-target synthetic-task '' draft-json '{"to":"x","subject":"x","body":"x"}' >/dev/null
refuse mint-grant "$STORE/fresh.json" booking synthetic-target synthetic-task 2030-01-01T00:00:00Z fresh "$TMP/queued.json" "$KEY" >/dev/null
control=$(find "$INSTALL/.action-control" -name brake.json -type f)
jq -e '.active and (.reconciliation[-1].queued | any(.approval_reference=="queued" and .status=="revoked-by-brake"))' "$control" >/dev/null || fail 'brake must reconcile queued grants'
call brake clear "$KEY" human-resume
refuse execute booking synthetic-target synthetic-task "$STORE/queued.json" /usr/bin/printf QUEUED_EXECUTED >/dev/null
request "$TMP/resumed.json" trusted booking /usr/bin/printf RESUMED_EXECUTED
mint resumed booking "$TMP/resumed.json"
out=$(call execute booking synthetic-target synthetic-task "$STORE/resumed.json" /usr/bin/printf RESUMED_EXECUTED)
assert_contains "$out" RESUMED_EXECUTED "fresh authorized operation should resume after clear"
pass "#16 brake stops queued/fresh actions and minting, records reconciliation, resumes with fresh authority"

# Authenticated state is required; deleting or changing the record fails closed.
cp "$control" "$TMP/control-copy"
chmod u+w "$control"
printf '{}\n' > "$control"
chmod a-w "$control"
refuse check draft synthetic-target synthetic-task >/dev/null
chmod u+w "$control"
cp "$TMP/control-copy" "$control"
chmod a-w "$control"
out=$(call check draft synthetic-target synthetic-task)
assert_contains "$out" ALLOW "restored signed brake state should evaluate"
pass "missing or tampered brake state never implies clear"

chmod u+w "$(dirname "$control")"
mv "$control" "$TMP/absent-control"
chmod a-w "$(dirname "$control")"
refuse check draft synthetic-target synthetic-task >/dev/null
chmod u+w "$(dirname "$control")"
mv "$TMP/absent-control" "$control"
chmod a-w "$(dirname "$control")"
pass "deleting brake state cannot clear the brake"

# Human mail prohibition remains unconditional and fail-closed evidence remains required.
refuse check mail_send synthetic@example.invalid synthetic-task >/dev/null
refuse check send synthetic@example.invalid synthetic-task >/dev/null
mkdir -p "$LAB/state/evidence.saved"
mv "$LAB/state/evidence/actions" "$LAB/state/evidence.saved/actions"
: > "$LAB/state/evidence/actions"
refuse execute draft synthetic-target synthetic-task '' draft-json '{"to":"x","subject":"x","body":"x"}' >/dev/null
rm "$LAB/state/evidence/actions"
mv "$LAB/state/evidence.saved/actions" "$LAB/state/evidence/actions"
pass "real mail stays denied and evidence failure denies execution"

# The lock spans the effect, not just its earlier policy check, and the child
# effect cannot inherit/unlock the gate's protected admission descriptor.
mkfifo "$TMP/release"
held_script='import os, signal, sys
signal.alarm(20)
open(sys.argv[1], "w").write("ready")
try:
    os.fstat(9)
except OSError:
    pass
else:
    sys.exit(91)
open(sys.argv[2]).readline()'
python=$(command -v python3)
request "$TMP/held.json" trusted booking "$python" -c "$held_script" "$TMP/admitted" "$TMP/release"
mint held booking "$TMP/held.json"
call execute booking synthetic-target synthetic-task "$STORE/held.json" "$python" -c "$held_script" \
  "$TMP/admitted" "$TMP/release" > "$TMP/held-output" 2>&1 &
held=$!
attempts=0
while [ ! -f "$TMP/admitted" ] && [ "$attempts" -lt 50 ]; do
  sleep 0.1
  attempts=$((attempts+1))
done
[ -f "$TMP/admitted" ] || fail "held synthetic effect never started"
out=$(refuse brake set "$KEY" while-effect-running)
assert_contains "$out" 'action admission busy' "brake must not report success across an admitted effect"
printf 'release\n' > "$TMP/release"
wait "$held" || fail 'effect inherited lock descriptor or failed'
call brake set "$KEY" after-effect
call brake clear "$KEY" after-effect-clear
pass "successful brake is serialized after admitted effects; child gets no lock capability"

# Concurrent admission still permits at most one execution of a signed grant.
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
pass "one-use consumption and serialized admission prevent concurrent replay"

# The existing no-mistakes lifecycle boundary must still fire after integrity.
out=$(env FM_HOME="$LAB" NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS='' bash "$ACTION_GATE" check draft synthetic-target synthetic-task 2>&1 || true)
assert_contains "$out" 'no-mistakes gate agent must not drive the fleet' "gate context must still refuse"
pass "no-mistakes fleet boundary preserved"
printf 'ok: T1 runtime regressions passed; installed ownership proof remains operator-owned\n'
