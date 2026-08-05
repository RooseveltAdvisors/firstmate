#!/usr/bin/env bash
# Hermetic contract tests for the opt-in Docker Sandboxes execution layer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sandbox)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_SBX_STATE="$TMP_ROOT/sbx-state"
FAKE_SBX_LOG="$TMP_ROOT/sbx.log"
STATE="$TMP_ROOT/state"
CONFIG="$TMP_ROOT/config"
SOURCE="$TMP_ROOT/source"
BRIEF="$TMP_ROOT/brief.md"
HOSTS="$CONFIG/sandbox-hosts.json"
ENABLE="$CONFIG/sandbox-workers-enabled"
ID="sbxtest$$"
TASK_TMP="/tmp/fm-$ID"
META="$STATE/$ID.meta"
OWNER="$STATE/$ID.sandbox.json"
NAME="fm-$ID-0123456789ab"
NONCE=0123456789abcdef0123456789abcdef
SCRIPT="$ROOT/bin/fm-sandbox.sh"
KIT="$ROOT/assets/sandbox-kits/firstmate-codex"

cleanup_test() {
  rm -rf "$TASK_TMP"
  fm_test_cleanup
}
trap cleanup_test EXIT
mkdir -p "$FAKE_SBX_STATE" "$STATE" "$CONFIG"
: > "$FAKE_SBX_LOG"

cat > "$HOSTS" <<'JSON'
{
  "version": 1,
  "hosts": [
    {
      "id": "dev",
      "role": "dev",
      "transport": "local",
      "hostname": "sandbox-test-host",
      "enabled": true,
      "priority": 10,
      "cpus": 3,
      "memory": "6GiB",
      "maxConcurrent": 2,
      "profiles": ["codex-github-bun-v1"],
      "authMode": "ephemeral-api-key",
      "privateNetworkGrant": false
    },
    {
      "id": "srv",
      "role": "srv",
      "transport": "ssh-fixed",
      "hostname": "srv",
      "enabled": false,
      "priority": 100,
      "cpus": 2,
      "memory": "4GiB",
      "maxConcurrent": 1,
      "profiles": ["codex-github-bun-v1"],
      "authMode": "ephemeral-api-key",
      "privateNetworkGrant": false
    }
  ]
}
JSON

cat > "$FAKEBIN/sbx" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_SBX_LOG"
state=$FM_FAKE_SBX_STATE
case "${1:-} ${2:-}" in
  "version ") printf '%s\n' 'Docker Sandboxes version 0.35.0' ;;
  "ls --json")
    if [ -f "$state/inventory.json" ]; then jq -s '.' "$state/inventory.json"; else printf '%s\n' '[]'; fi
    ;;
  "policy ls") printf '%s\n' '[{"name":"deny-all","source":"local","status":"active"}]' ;;
  "policy check")
    target=${@: -1}
    case "$target" in
      api.openai.com|github.com|registry.npmjs.org|registry-1.docker.io) printf 'Allowed: %s\n' "$target" ;;
      *) printf 'Denied: %s\n' "$target" ;;
    esac
    ;;
  "policy log") printf '%s\n' '[{"decision":"deny","host":"portal.arcs.health"}]' ;;
  "create --name")
    name=$3
    workspace=${@: -1}
    jq -nc --arg name "$name" --arg workspace "$workspace" \
      '{name:$name,id:"sbx-stable-001",workspace:$workspace}' > "$state/inventory.json"
    ;;
  "exec "*)
    name=$2
    [ "$(jq -r .name "$state/inventory.json")" = "$name" ] || exit 40
    [ "${3:-}" = -- ] || exit 43
    if [ "${4:-}" = cat ]; then
      cat "$state/owner.json"
    else
      printf '%s\n' "${@: -1}" > "$state/owner.json"
    fi
    ;;
  "secret set")
    secret=$(cat)
    [ "$secret" = ephemeral-openai-test ] || [ "$secret" = ephemeral-github-test ] || exit 41
    printf '%s\n' "$3:$4" >> "$state/secrets"
    ;;
  "run --name")
    workspace=$(jq -r .workspace "$state/inventory.json")
    printf '%s\n' '# changed safely inside fake microVM' >> "$workspace/README.md"
    git -C "$workspace" add README.md
    git -C "$workspace" -c user.name='Sandbox Test' -c user.email='sandbox@example.invalid' commit -qm sandbox-change
    printf '%s\n' 'done: fake sandbox edit, build, and test complete' >> "$workspace/.firstmate/status"
    touch "$workspace/.firstmate/turn-ended"
    sleep 2
    ;;
  "rm --force") rm -f "$state/inventory.json" ;;
  *) echo "unexpected fake sbx invocation: $*" >&2; exit 42 ;;
esac
SH
chmod +x "$FAKEBIN/sbx"

run_sandbox() {
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_SANDBOX_HOSTS_OVERRIDE="$HOSTS" \
    FM_SANDBOX_ENABLE_OVERRIDE="$ENABLE" FM_SANDBOX_KVM_PATH=/dev/null \
    FM_SANDBOX_HOSTNAME=sandbox-test-host FM_SANDBOX_SBX=sbx \
    FM_FAKE_SBX_STATE="$FAKE_SBX_STATE" FM_FAKE_SBX_LOG="$FAKE_SBX_LOG" \
    "$SCRIPT" "$@"
}

write_meta() {
  fm_write_meta "$META" \
    'window=fm-lab-test:pane-1' \
    "worktree=$SOURCE" \
    "project=$SOURCE" \
    'harness=codex' \
    'kind=ship' \
    'mode=local-only' \
    'yolo=off' \
    "tasktmp=$TASK_TMP" \
    'model=default' \
    'effort=high' \
    'execution=sandbox' \
    'backend=herdr' \
    'herdr_session=fm-lab-test' \
    'herdr_workspace_id=workspace-1' \
    'herdr_tab_id=tab-1' \
    'herdr_pane_id=pane-1' \
    'sandbox_host=dev' \
    'sandbox_profile=codex-github-bun-v1' \
    "sandbox_name=$NAME" \
    "sandbox_nonce=$NONCE" \
    "sandbox_owner=$OWNER" \
    "sandbox_brief=$BRIEF"
}

test_rollout_disabled_is_non_mutating() {
  local out
  : > "$FAKE_SBX_LOG"
  out=$(run_sandbox inventory --json)
  [ "$(jq -r .rolloutEnabled <<EOF
$out
EOF
)" = false ] || fail "inventory should report tracked rollout disabled"
  assert_not_contains "$(cat "$FAKE_SBX_LOG")" "ls --json" "disabled inventory must not start or query the sbx daemon"
  assert_not_contains "$(cat "$FAKE_SBX_LOG")" "policy ls" "disabled inventory must not inspect live policy"
  pass "fm-sandbox: rollout is disabled and non-mutating by default"
}

test_doctor_and_role_facts() {
  local out
  printf '%s\n' v1 > "$ENABLE"
  out=$(run_sandbox doctor --host dev --json)
  [ "$(jq -r .eligible <<EOF
$out
EOF
)" = true ] || fail "doctor should accept the complete local microVM capability fixture: $out"
  [ "$(jq -r .limits.cpus <<EOF
$out
EOF
)" = 3 ] || fail "doctor did not preserve inspectable CPU limits"
  out=$(run_sandbox inventory --json)
  [ "$(jq -r '.hosts[] | select(.id == "srv") | .refusalReason' <<EOF
$out
EOF
)" = host-disabled ] || fail "inventory did not report the production host refusal fact"
  pass "fm-sandbox: doctor reports exact host capabilities, roles, and limits without a scheduler score"
}

test_prepare_run_sync_and_cleanup() {
  local out log marker rm_before rm_after
  fm_git_init_commit "$SOURCE"
  git -C "$SOURCE" branch -M "fm/$ID"
  printf '%s\n' 'never copy this ignored secret' > "$SOURCE/.env"
  printf '%s\n' '.env' > "$SOURCE/.gitignore"
  git -C "$SOURCE" add .gitignore
  git -C "$SOURCE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm ignore-env
  printf '%s\n' '# fixture brief' > "$BRIEF"
  write_meta

  if run_sandbox prepare "$ID" >/dev/null 2>&1; then
    fail "prepare should refuse without an ephemeral task-scoped OpenAI key"
  fi
  assert_absent "$OWNER" "credential refusal should happen before ownership publication or sandbox creation"

  FM_SANDBOX_OPENAI_API_KEY=ephemeral-openai-test \
    FM_SANDBOX_GITHUB_TOKEN=ephemeral-github-test run_sandbox prepare "$ID"
  assert_present "$OWNER" "prepare did not publish machine-readable ownership metadata"
  [ "$(jq -r .sandbox_id "$OWNER")" = sbx-stable-001 ] || fail "stable sandbox id was not recorded"
  [ "$(jq -r .host_id "$OWNER")" = dev ] || fail "exact host was not recorded"
  [ "$(jq -r .limits.cpus "$OWNER")" = 3 ] || fail "CPU limit was not recorded"
  assert_absent "$TASK_TMP/sandbox/workcopy/.env" "ignored production-like .env leaked into disposable clone"
  marker=$(cat "$FAKE_SBX_STATE/owner.json")
  [ "$(jq -r .nonce <<EOF
$marker
EOF
)" = "$NONCE" ] || fail "in-VM immutable ownership marker lacks the task nonce"
  log=$(cat "$FAKE_SBX_LOG")
  assert_contains "$log" "create --name $NAME --cpus 3 --memory 6GiB --no-share-skills --kit $KIT codex $TASK_TMP/sandbox/workcopy" \
    "prepare did not use bounded resources, the pinned kit, or private skill isolation"
  assert_not_contains "$log" "/var/run/docker.sock" "prepare exposed the host Docker socket"
  assert_not_contains "$log" "docker run" "prepare fell back to an ordinary container"
  assert_not_contains "$log" "--mount $HOME" "prepare mounted the host home"
  assert_not_contains "$log" ".ssh" "prepare exposed host SSH state"
  assert_not_contains "$log" ".codex" "prepare exposed persistent Codex authentication state"
  assert_contains "$log" "policy check network --sandbox $NAME portal.arcs.health" "production-domain deny was not verified"
  assert_contains "$log" "policy check network --sandbox $NAME 192.168.0.6" "fleet-private IP deny was not verified"

  run_sandbox run "$ID"
  assert_grep '# changed safely inside fake microVM' "$SOURCE/README.md" "committed sandbox edit was not fast-forwarded to the ordinary task worktree"
  assert_grep 'done: fake sandbox edit, build, and test complete' "$STATE/$ID.status" "task-scoped status bridge did not surface sandbox completion"
  assert_present "$STATE/$ID.turn-ended" "task-scoped turn-end bridge did not surface the Codex turn"
  assert_present "$STATE/$ID.sandbox-network.json" "task-scoped sandbox policy log was not recorded"
  [ "$(jq -r .synced_commit "$OWNER")" = "$(git -C "$SOURCE" rev-parse HEAD)" ] || fail "synced commit was not recorded exactly"

  cp "$FAKE_SBX_STATE/owner.json" "$FAKE_SBX_STATE/owner.good"
  jq '.nonce="wrong"' "$FAKE_SBX_STATE/owner.good" > "$FAKE_SBX_STATE/owner.json"
  rm_before=$(grep -c '^rm --force' "$FAKE_SBX_LOG" || true)
  if run_sandbox cleanup "$ID" >/dev/null 2>&1; then
    fail "cleanup should refuse a mismatched immutable ownership nonce"
  fi
  rm_after=$(grep -c '^rm --force' "$FAKE_SBX_LOG" || true)
  [ "$rm_before" = "$rm_after" ] || fail "mismatched ownership reached destructive sbx rm"
  cp "$FAKE_SBX_STATE/owner.good" "$FAKE_SBX_STATE/owner.json"
  run_sandbox cleanup "$ID"
  [ "$(jq -r .lifecycle "$OWNER")" = removed ] || fail "bounded cleanup did not record removal"
  assert_absent "$FAKE_SBX_STATE/inventory.json" "bounded cleanup left the exact sandbox present"
  pass "fm-sandbox: prepare, status bridge, committed-work sync, immutable ownership, and bounded cleanup are vertical"
}

test_static_lifecycle_boundaries() {
  local spawn teardown sandbox kit
  spawn=$(cat "$ROOT/bin/fm-spawn.sh")
  teardown=$(cat "$ROOT/bin/fm-teardown.sh")
  sandbox=$(cat "$SCRIPT")
  kit=$(cat "$KIT/spec.yaml")
  assert_contains "$spawn" 'sandbox execution requires backend=herdr' "spawn does not pin Herdr as the only sandbox runtime"
  assert_contains "$spawn" 'sandbox execution supports only verified harness=codex' "unsupported harnesses do not refuse explicitly"
  # shellcheck disable=SC2016
  assert_contains "$teardown" '"$FM_ROOT/bin/fm-sandbox.sh" cleanup "$ID"' "ordinary teardown does not own sandbox cleanup ordering"
  assert_not_contains "$sandbox" 'docker run --privileged' "sandbox owner contains a privileged-container fallback"
  assert_not_contains "$sandbox" '--volume /var/run/docker.sock' "sandbox owner mounts the host Docker socket"
  assert_not_contains "$sandbox" 'DOCKER_HOST=' "sandbox owner redirects to an ambient host Docker daemon"
  assert_not_contains "$sandbox" 'ssh ' "v1 introduced an SSH command-string boundary"
  assert_contains "$kit" '"*.arcs.health"' "kit does not deny production domains"
  assert_contains "$kit" '"*.home.arcs.internal"' "kit does not deny fleet-private domains"
  assert_contains "$kit" 'scopey setup' "every supported sandbox worker does not install Scopey"
  assert_contains "$kit" 'Scopey never authorizes stopping work' "Scopey is not explicitly advisory"
  pass "fm-sandbox: runtime, harness, network, mount, Scopey, and remote-boundary contracts are explicit"
}

test_rollout_disabled_is_non_mutating
test_doctor_and_role_facts
test_prepare_run_sync_and_cleanup
test_static_lifecycle_boundaries
