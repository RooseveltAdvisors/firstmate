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
for enforcement in fm-action-gate.sh fm-action-gate-lib.sh fm-action-request.py fm-gate-refuse-lib.sh; do
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

for enforcement in fm-action-gate.sh fm-action-gate-lib.sh fm-action-request.py fm-gate-refuse-lib.sh; do
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
for fixture_kind in forwarded-mail vendor-document chat-transcript web-page repository-note; do
  draft=$(jq -nc --arg text "$fixture_kind: SYNTHETIC_INJECTION \$(touch $TMP/unsafe-draft-effect)" '{to:"synthetic@example.invalid",subject:"Synthetic",body:$text}')
  out=$(call execute mail_draft synthetic-target synthetic-task '' draft-json "$draft")
  assert_contains "$out" '"operation": "mail_draft"' 'untrusted draft content must remain data'
done
[ ! -e "$TMP/unsafe-draft-effect" ] || fail 'untrusted draft content executed'
pass 'five external-content draft fixtures render as data without executable authority'

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

HTTP_DOCUMENT=$(jq -nc '{url:"http://127.0.0.1:1/approved",method:"POST",account_id:"synthetic-approved",credential_id:"synthetic-approved",headers:{Authorization:"Bearer SYNTHETIC_APPROVED"},body:{effect:"SYNTHETIC_APPROVED_PAYLOAD"}}')

server_pid=''
stop_server() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap 'stop_server; fm_test_cleanup' EXIT

# Real synthetic endpoint for the protected executor. It captures what was sent,
# independently of the grant checker and its output.
python3 - "$TMP" <<'PY' &
import hashlib, http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        body = json.loads(raw) if raw else {}
        record = {'path': self.path, 'account': self.headers.get('X-Account-ID'), 'credential': self.headers.get('X-Credential-ID'), 'authorization': self.headers.get('Authorization'), 'body': body, 'payload_sha256': hashlib.sha256(raw).hexdigest()}
        with (root / 'requests.jsonl').open('a') as output:
            output.write(json.dumps(record) + '\n')
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/redirected-effect')
        else:
            self.send_response(204)
        self.end_headers()
    def do_GET(self):
        self.do_POST()
    def log_message(self, fmt, *args):
        with (root / 'server.log').open('a') as output:
            output.write((fmt % args) + '\n')
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
for _ in {1..100}; do
  [ ! -s "$TMP/port" ] || break
  sleep 0.1
done
[ -s "$TMP/port" ] || fail 'synthetic HTTP endpoint did not start'
HTTP_DOCUMENT=$(printf '%s' "$HTTP_DOCUMENT" | jq -c --arg url "http://127.0.0.1:$(cat "$TMP/port")/approved" '.url=$url')
request "$TMP/request.json" trusted booking http-json "$HTTP_DOCUMENT"

# Policy component regression. Its explicit precondition is an authenticated
# in-memory grant snapshot; this does not replace the real root-store cases.
component_policy() {
  local file=$1
  shift
  FM_HOME="$LAB" bash -c '
    . "$1/bin/fm-action-gate-lib.sh"
    FM_ACTION_GRANT_PATH=$2
    FM_ACTION_GRANT_JSON=$(cat "$2")
    shift 2
    fm_action_gate_payload booking synthetic-target synthetic-task "$FM_ACTION_GRANT_PATH" "$@" || exit 1
    if [ "${COMPONENT_SEND:-0}" = 1 ]; then fm_action_gate_http_execute; fi
  ' _ "$SOURCE" "$file" "$@"
}
request "$TMP/component-request.json" trusted booking http-json "$HTTP_DOCUMENT"
python3 -I "$SOURCE/bin/fm-action-request.py" mint booking < "$TMP/component-request.json" > "$TMP/component-bound.json"
jq '. + {schema:"fm-action-grant.v2"}' "$TMP/component-bound.json" > "$TMP/component-grant.json"
component_policy "$TMP/component-grant.json" http-json "$HTTP_DOCUMENT"
export SYNTHETIC_HOOK_MARKER="$TMP/unsafe-env-hook"
env() { printf 'UNSAFE_ENV_HOOK\n' > "$SYNTHETIC_HOOK_MARKER"; return 0; }
export -f env
out=$(COMPONENT_SEND=1 HTTP_PROXY=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1 SYNTHETIC_ACCOUNT=synthetic-changed component_policy "$TMP/component-grant.json" http-json "$HTTP_DOCUMENT")
unset -f env
assert_contains "$out" 'status=204' 'typed HTTP adapter must use the approved snapshot independently of proxy, account or imported env hook'
[ ! -e "$SYNTHETIC_HOOK_MARKER" ] || fail 'HTTP adapter invoked the caller env function'
tail -n 1 "$TMP/requests.jsonl" | jq -e '.path=="/approved" and .account=="synthetic-approved" and .credential=="synthetic-approved" and .authorization=="Bearer SYNTHETIC_APPROVED" and .body.effect=="SYNTHETIC_APPROVED_PAYLOAD"' >/dev/null || fail 'typed HTTP adapter sent substituted account or payload data'
tail -n 1 "$TMP/requests.jsonl" | jq -e --arg digest "$(jq -r .payload_sha256 "$TMP/component-grant.json")" '.payload_sha256==$digest' >/dev/null || fail 'wire payload bytes differ from the approved payload digest'
for field in url account_id credential_id body; do
  changed=$(printf '%s' "$HTTP_DOCUMENT" | jq -c --arg field "$field" 'if $field=="body" then .body={effect:"SYNTHETIC_CHANGED_PAYLOAD"} else .[$field]="synthetic-changed" end')
  if component_policy "$TMP/component-grant.json" http-json "$changed" > "$TMP/component-output" 2>&1; then
    fail "changed $field passed the approved request binding"
  fi
done
changed=$(printf '%s' "$HTTP_DOCUMENT" | jq -c '.body={effect:"SYNTHETIC_CHANGED_PAYLOAD"}')
jq --arg changed "$changed" '.request.argv[1]=$changed' "$TMP/component-grant.json" > "$TMP/stale-digest.json"
if component_policy "$TMP/stale-digest.json" http-json "$changed" > "$TMP/component-output" 2>&1; then
  fail 'changed request with stale digest passed'
fi
assert_contains "$(cat "$TMP/component-output")" 'mismatched approved request digest' 'stale digest must be checked on an otherwise valid typed request'
jq '.payload_sha256="invalid"' "$TMP/component-grant.json" > "$TMP/stale-payload-digest.json"
if component_policy "$TMP/stale-payload-digest.json" http-json "$HTTP_DOCUMENT" > "$TMP/component-output" 2>&1; then fail 'invalid wire payload digest passed'; fi
duplicate_document=$(printf '%s' "$HTTP_DOCUMENT" | sed 's/^{/{"account_id":"synthetic-conflicting",/')
request "$TMP/duplicate.json" trusted booking http-json "$duplicate_document"
if python3 -I "$SOURCE/bin/fm-action-request.py" mint booking < "$TMP/duplicate.json" > "$TMP/component-output" 2>&1; then fail 'ambiguous duplicate account field was approved'; fi
request "$TMP/external-request.json" trusted booking /usr/bin/python3 "$TMP/mutable-payload.py"
if python3 -I "$SOURCE/bin/fm-action-request.py" mint booking < "$TMP/external-request.json" > "$TMP/component-output" 2>&1; then
  fail 'mutable executable payload request was approved'
fi
request "$TMP/forwarded-request.json" untrusted-forwarded mail_send http-json "$HTTP_DOCUMENT"
if python3 -I "$SOURCE/bin/fm-action-request.py" mint booking < "$TMP/forwarded-request.json" > "$TMP/component-output" 2>&1; then
  fail 'forwarded mail_send was relabeled as booking'
fi
redirect_document=$(printf '%s' "$HTTP_DOCUMENT" | jq -c '.url|=sub("/approved$";"/redirect")')
request "$TMP/component-redirect.json" trusted booking http-json "$redirect_document"
python3 -I "$SOURCE/bin/fm-action-request.py" mint booking < "$TMP/component-redirect.json" | jq '. + {schema:"fm-action-grant.v2"}' > "$TMP/component-redirect-grant.json"
if COMPONENT_SEND=1 component_policy "$TMP/component-redirect-grant.json" http-json "$redirect_document" > "$TMP/component-output" 2>&1; then fail 'redirect completed as an approved action'; fi
assert_contains "$(cat "$TMP/component-output")" 'redirects and fallback refuse' 'redirect refusal must be explicit'
if jq -se 'any(.[]; .path=="/redirected-effect")' "$TMP/requests.jsonl" >/dev/null; then fail 'HTTP adapter followed a changed-destination redirect'; fi
pass 'component binding: approved typed snapshot passes; destination, account, credential, body, executable file and provenance substitutions deny (not root-store proof)'

STORE=$(call grant-store)
mkdir -p "$STORE"
request "$TMP/request.json" trusted booking http-json "$HTTP_DOCUMENT"
jq -nc --slurpfile request "$TMP/request.json" \
  '{action_class:"booking",target:"synthetic-target",task_id:"synthetic-task",expires_at:"2030-01-01T00:00:00Z",approval_reference:"worker-forged",used_at:null,request:$request[0]}' > "$STORE/worker-forged.json"
chmod a-w "$STORE/worker-forged.json" "$STORE" "$(dirname "$STORE")" "$(dirname "$(dirname "$STORE")")"
refuse execute booking synthetic-target synthetic-task "$STORE/worker-forged.json" http-json "$HTTP_DOCUMENT" >/dev/null
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
trap 'stop_server; restore_fixture; fm_test_cleanup' EXIT
sudo -n chown -R 0:0 "$INSTALL/bin" "$INSTALL/.action-control"
sudo -n chmod -R go-w "$INSTALL/bin" "$INSTALL/.action-control"
admin() { sudo -n /usr/bin/env FM_HOME="$LAB" bash "$ACTION_GATE" "$@"; }
mint() {
  local name=$1 class=$2 request_file=$3
  admin mint-grant "$STORE/$name.json" "$class" synthetic-target synthetic-task \
    2030-01-01T00:00:00Z "$name" "$request_file"
}

for action in booking charging prod_deploy deploy; do
  request "$TMP/request-$action.json" trusted "$action" http-json "$HTTP_DOCUMENT"
  mint "valid-$action" "$action" "$TMP/request-$action.json"
  out=$(call execute "$action" synthetic-target synthetic-task "$STORE/valid-$action.json" http-json "$HTTP_DOCUMENT")
  assert_contains "$out" 'approved HTTP action completed, status=204' 'plain root-owned grant must execute'
  tail -n 1 "$TMP/requests.jsonl" | jq -e --arg digest "$(jq -r .payload_sha256 "$STORE/valid-$action.json")" '.payload_sha256==$digest' >/dev/null || fail 'protected grant payload digest differs from actual wire bytes'
  refuse execute "$action" synthetic-target synthetic-task "$STORE/valid-$action.json" http-json "$HTTP_DOCUMENT" >/dev/null
done
pass 'step1(c): plain protected grants admit booking, charging and deploy once, without keys or brake state'

# Neither malformed JSON nor writable authority is an empty/missing grant.
printf '{' > "$TMP/malformed.json"
sudo -n cp "$TMP/malformed.json" "$STORE/malformed.json"
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/malformed.json" http-json "$HTTP_DOCUMENT")
assert_contains "$out" 'unprotected or malformed JSON' 'malformed grant must hard deny'
mint writable booking "$TMP/request.json"
sudo -n chmod 666 "$STORE/writable.json"
refuse execute booking synthetic-target synthetic-task "$STORE/writable.json" http-json "$HTTP_DOCUMENT" >/dev/null
pass 'malformed and worker-writable grants hard deny'

mint mismatch booking "$TMP/request.json"
refuse execute booking wrong-target synthetic-task "$STORE/mismatch.json" http-json "$HTTP_DOCUMENT" >/dev/null
refuse execute booking synthetic-target wrong-task "$STORE/mismatch.json" http-json "$HTTP_DOCUMENT" >/dev/null
refuse execute charging synthetic-target synthetic-task "$STORE/mismatch.json" http-json "$HTTP_DOCUMENT" >/dev/null
out=$(refuse execute booking synthetic-target synthetic-task "$STORE/mismatch.json" /usr/bin/printf UNAPPROVED)
assert_contains "$out" 'command differs from approved payload' 'grant must still bind exact argv'
pass 'class, target, task and exact payload binding preserved'

request "$TMP/forwarded.json" untrusted-forwarded mail_send http-json "$HTTP_DOCUMENT"
if out=$(mint forwarded booking "$TMP/forwarded.json" 2>&1); then fail 'forwarded mail was approved as booking'; fi
assert_contains "$out" 'provenance origin' 'mail_send cannot be approved under a booking label'
pass 'forwarded mail provenance remains bound to the approved action'

before_count=$(wc -l < "$TMP/requests.jsonl")
mint substitutions booking "$TMP/request.json"
for field in url account_id credential_id headers body; do
  changed=$(printf '%s' "$HTTP_DOCUMENT" | jq -c --arg field "$field" 'if $field=="body" then .body={effect:"SYNTHETIC_CHANGED_PAYLOAD"} elif $field=="headers" then .headers={Authorization:"Bearer SYNTHETIC_CHANGED"} elif $field=="url" then .url+="-changed" else .[$field]="synthetic-changed" end')
  refuse execute booking synthetic-target synthetic-task "$STORE/substitutions.json" http-json "$changed" >/dev/null
done
[ "$(wc -l < "$TMP/requests.jsonl")" -eq "$before_count" ] || fail 'substituted request reached the endpoint'
out=$(HTTP_PROXY=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1 SYNTHETIC_ACCOUNT=synthetic-changed call execute booking synthetic-target synthetic-task "$STORE/substitutions.json" http-json "$HTTP_DOCUMENT")
assert_contains "$out" 'status=204' 'unconsumed approved request must succeed independently of inherited account/proxy settings'
tail -n 1 "$TMP/requests.jsonl" | jq -e '.path=="/approved" and .account=="synthetic-approved" and .credential=="synthetic-approved" and .authorization=="Bearer SYNTHETIC_APPROVED" and .body.effect=="SYNTHETIC_APPROVED_PAYLOAD"' >/dev/null || fail 'endpoint observed unapproved account, credential or payload'
pass 'protected-grant integration: changed URL, account, credential, authorization and body deny without effects; unchanged request survives hostile inherited settings'

redirect_document=$(printf '%s' "$HTTP_DOCUMENT" | jq -c '.url|=sub("/approved$";"/redirect")')
request "$TMP/redirect.json" trusted booking http-json "$redirect_document"
mint redirect booking "$TMP/redirect.json"
refuse execute booking synthetic-target synthetic-task "$STORE/redirect.json" http-json "$redirect_document" >/dev/null
if jq -se 'any(.[]; .path=="/redirected-effect")' "$TMP/requests.jsonl" >/dev/null; then fail 'approved endpoint redirect was followed'; fi
pass 'approved destination cannot redirect execution to a different target'

admin mint-grant "$STORE/expired.json" booking synthetic-target synthetic-task \
  2020-01-01T00:00:00Z expired "$TMP/request.json"
out=$(refuse check booking synthetic-target synthetic-task "$STORE/expired.json")
assert_contains "$out" 'grant has expired' 'expiry remains enforced'
pass 'plain grants still expire'

request "$TMP/concurrent.json" trusted booking http-json "$HTTP_DOCUMENT"
mint concurrent booking "$TMP/concurrent.json"
pids=()
for i in 1 2 3 4; do
  call execute booking synthetic-target synthetic-task "$STORE/concurrent.json" http-json "$HTTP_DOCUMENT" > "$TMP/concurrent-$i" 2>&1 &
  pids+=("$!")
done
success=0
for pid in "${pids[@]}"; do
  if wait "$pid"; then success=$((success+1)); fi
done
[ "$success" -eq 1 ] || fail "expected one concurrent execution, got $success"
pass 'atomic consumption admits only one concurrent execution'
printf 'ok: all Step 1 action gate regressions passed with real root-owned grants\n'
