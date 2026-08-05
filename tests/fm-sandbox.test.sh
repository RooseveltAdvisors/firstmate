#!/usr/bin/env bash
# Hermetic tests for the inert Docker Sandboxes Stage 1 lifecycle journal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sandbox)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STATE="$TMP_ROOT/state"
CONFIG="$TMP_ROOT/config"
HOSTS="$CONFIG/sandbox-hosts.json"
SBX_LOG="$TMP_ROOT/sbx.log"
SOURCE="$TMP_ROOT/source"
TASK_BASE="$TMP_ROOT/task-roots"
SCRIPT="$ROOT/bin/fm-sandbox.sh"
REAL_MKDIR=$(command -v mkdir)

ID_MAIN="sbxmain$$"
ID_ROLLBACK="sbxrollback$$"
ID_CRASH="sbxcrash$$"
ID_RESERVATION_CRASH="sbxreservationcrash$$"
ID_COMMIT_CRASH="sbxcommitcrash$$"
ID_CLEAN_LOCAL_CRASH="sbxcleanlocalcrash$$"
ID_CLEAN_RELEASE_CRASH="sbxcleanreleasecrash$$"
ID_ROLLBACK_CRASH="sbxrollbackcrash$$"
ID_CAP_A="sbxcapa$$"
ID_CAP_B="sbxcapb$$"
ID_LINK="sbxlink$$"
ID_RACE="sbxrace$$"
ID_PARTIAL="sbxpartial$$"
ID_MISSING="sbxmissing$$"
ID_OVERLAP="sbxoverlap$$"
ID_EQUAL="sbxequal$$"
ID_SOURCE_GONE="sbxsourcegone$$"
ID_SOURCE_REUSE="sbxsourcereuse$$"
ID_IGNORED="sbxignored$$"
ID_COORD="sbxcoord$$"

NONCE_MAIN=11111111111111111111111111111111
NONCE_ROLLBACK=22222222222222222222222222222222
NONCE_CRASH=33333333333333333333333333333333
NONCE_RESERVATION_CRASH=99999999999999999999999999999999
NONCE_COMMIT_CRASH=44444444444444444444444444444444
NONCE_CLEAN_LOCAL_CRASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NONCE_CLEAN_RELEASE_CRASH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NONCE_ROLLBACK_CRASH=55555555555555555555555555555555
NONCE_CAP_A=66666666666666666666666666666666
NONCE_CAP_B=77777777777777777777777777777777
NONCE_LINK=88888888888888888888888888888888
NONCE_RACE=12121212121212121212121212121212
NONCE_PARTIAL=13131313131313131313131313131313
NONCE_MISSING=14141414141414141414141414141414
NONCE_OVERLAP=15151515151515151515151515151515
NONCE_EQUAL=16161616161616161616161616161616
NONCE_SOURCE_GONE=17171717171717171717171717171717
NONCE_SOURCE_REUSE=19191919191919191919191919191919
NONCE_IGNORED=18181818181818181818181818181818
NONCE_COORD=20202020202020202020202020202020

cleanup_test() {
  local id
  for id in "$ID_MAIN" "$ID_ROLLBACK" "$ID_CRASH" "$ID_COMMIT_CRASH" \
    "$ID_CLEAN_LOCAL_CRASH" "$ID_CLEAN_RELEASE_CRASH" "$ID_RESERVATION_CRASH" \
    "$ID_ROLLBACK_CRASH" "$ID_CAP_A" "$ID_CAP_B" "$ID_LINK" "$ID_RACE" \
    "$ID_PARTIAL" "$ID_MISSING" "$ID_OVERLAP" "$ID_EQUAL" "$ID_SOURCE_GONE" \
    "$ID_SOURCE_REUSE" "$ID_IGNORED" "$ID_COORD"; do
    rm -rf -- "$TASK_BASE/fm-$id"
  done
  fm_test_cleanup
}
trap cleanup_test EXIT

mkdir -p "$STATE" "$CONFIG" "$TASK_BASE"
cp "$ROOT/docs/examples/sandbox-hosts.json" "$HOSTS"
tmp_hosts=$(mktemp "$TMP_ROOT/hosts.XXXXXX")
jq '(.hosts[] | select(.id == "dev") | .hostname) = "sandbox-test-host"
    | (.hosts[] | select(.id == "dev") | .maxConcurrent) = 1' "$HOSTS" > "$tmp_hosts"
mv "$tmp_hosts" "$HOSTS"
: > "$SBX_LOG"

cat > "$FAKEBIN/sbx" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_SBX_LOG"
case "${1:-}" in
  version) printf '%s\n' 'Docker Sandboxes version 0.35.0' ;;
  *) echo "unexpected Stage 1 sbx operation: $*" >&2; exit 42 ;;
esac
SH
chmod +x "$FAKEBIN/sbx"

cat > "$FAKEBIN/mkdir" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${FM_SANDBOX_TEST_COORDINATION_RACE:-}" = 1 ] \
    && [ "$#" = 1 ] && [ "$1" = "${FM_SANDBOX_COORDINATION_ROOT:-}" ]; then
  "$FM_REAL_MKDIR" "$@"
  exit 1
fi
exec "$FM_REAL_MKDIR" "$@"
SH
chmod +x "$FAKEBIN/mkdir"

run_sandbox() {
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_SANDBOX_HOSTS_OVERRIDE="${FM_SANDBOX_HOSTS_OVERRIDE:-$HOSTS}" \
    FM_SANDBOX_TASK_ROOT_BASE="${FM_SANDBOX_TASK_ROOT_BASE:-$TASK_BASE}" \
    FM_SANDBOX_HOSTNAME=sandbox-test-host FM_SANDBOX_KVM_PATH=/dev/null \
    FM_SANDBOX_SBX=sbx FM_FAKE_SBX_LOG="$SBX_LOG" FM_REAL_MKDIR="$REAL_MKDIR" \
    "$SCRIPT" "$@"
}

task_root() {
  printf '%s/fm-%s\n' "$TASK_BASE" "$1"
}

owner_path() {
  printf '%s/%s.sandbox.json\n' "$STATE" "$1"
}

prepare_task() {
  local id=$1 nonce=$2
  run_sandbox prepare "$id" --host dev --name "fm-$id" --nonce "$nonce" \
    --source "$SOURCE" --task-root "$(task_root "$id")"
}

assert_lifecycle() {
  local id=$1 expected=$2 owner
  owner=$(owner_path "$id")
  [ "$(jq -r .lifecycle "$owner")" = "$expected" ] \
    || fail "task $id lifecycle is not $expected"
}

make_source() {
  fm_git_init_commit "$SOURCE"
  printf '%s\n' '.env' > "$SOURCE/.gitignore"
  printf '%s\n' 'production-like secret that must not clone' > "$SOURCE/.env"
  git -C "$SOURCE" add .gitignore
  git -C "$SOURCE" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm ignore-env
}

test_inventory_doctor_and_policy_contract() {
  local out bad
  : > "$SBX_LOG"
  out=$(run_sandbox inventory --json)
  [ "$(jq -r .stage <<EOF
$out
EOF
)" = 1 ] || fail "inventory does not identify inert Stage 1"
  [ "$(jq -r .launchEnabled <<EOF
$out
EOF
)" = false ] || fail "inventory claims launch is enabled"
  [ "$(jq -r .policy.mode <<EOF
$out
EOF
)" = deny-all ] || fail "inventory lost the deny-all policy contract"
  [ "$(jq -r .policy.hostDockerSocket <<EOF
$out
EOF
)" = false ] || fail "inventory permits the host Docker socket"
  [ "$(jq -r '.policy.hostMounts | length' <<EOF
$out
EOF
)" = 0 ] || fail "inventory permits host mounts"
  out=$(run_sandbox doctor --host dev --json)
  [ "$(jq -r .launchSupported <<EOF
$out
EOF
)" = false ] || fail "doctor authorizes Stage 1 launch"
  [ "$(jq -r .refusalReason <<EOF
$out
EOF
)" = stage1-journal-only ] || fail "doctor did not report the explicit Stage 1 refusal"
  out=$(run_sandbox doctor --host srv --json)
  [ "$(jq -r .refusalReason <<EOF
$out
EOF
)" = production-role-deferred ] || fail "doctor did not report the production role refusal"
  assert_not_contains "$(cat "$SBX_LOG")" 'ls --json' "doctor queried the sandbox daemon"
  assert_not_contains "$(cat "$SBX_LOG")" 'policy' "doctor queried live policy"
  [ "$(sort -u "$SBX_LOG")" = version ] \
    || fail "inventory or doctor called more than the read-only sbx version command"

  bad=$(mktemp "$TMP_ROOT/bad-hosts.XXXXXX")
  jq '.policy.mode="balanced"' "$HOSTS" > "$bad"
  if FM_SANDBOX_HOSTS_OVERRIDE="$bad" run_sandbox inventory --json >/dev/null 2>&1; then
    fail "inventory accepted a non-deny-all contract"
  fi
  pass "fm-sandbox: inventory and doctor are read-only, role-aware, and deny-by-default"
}

test_concurrent_coordination_initialization() {
  local coordination="$STATE/concurrent-coordination"
  FM_SANDBOX_COORDINATION_ROOT="$coordination" \
    FM_SANDBOX_TEST_COORDINATION_RACE=1 \
    prepare_task "$ID_COORD" "$NONCE_COORD"
  FM_SANDBOX_COORDINATION_ROOT="$coordination" run_sandbox rollback "$ID_COORD"
  pass "fm-sandbox: concurrent first-use coordination initialization is idempotent"
}

test_prepare_commit_and_cleanup_journal() {
  local owner reservation receipt
  prepare_task "$ID_MAIN" "$NONCE_MAIN"
  owner=$(owner_path "$ID_MAIN")
  assert_present "$owner" "prepare did not publish its ownership journal"
  assert_lifecycle "$ID_MAIN" prepared
  [ "$(jq -r .sandbox_id "$owner")" = null ] || fail "prepare fabricated a stable sandbox id"
  [ "$(jq -r .stage "$owner")" = 1 ] || fail "journal does not identify Stage 1"
  [ "$(jq -r .task_id "$owner")" = "$ID_MAIN" ] || fail "journal lost its exact task identity"
  [ "$(jq -r .host_id "$owner")" = dev ] || fail "journal lost its exact host identity"
  [ "$(jq -r .sandbox_name "$owner")" = "fm-$ID_MAIN" ] || fail "journal lost its sandbox name"
  [ "$(jq -r .nonce "$owner")" = "$NONCE_MAIN" ] || fail "journal lost its ownership nonce"
  [ "$(jq -r .limits.maxConcurrent "$owner")" = 1 ] || fail "journal lost the host concurrency limit"
  assert_absent "$(task_root "$ID_MAIN")/sandbox/workcopy/.env" \
    "committed-only clone copied an ignored secret"
  reservation=$(jq -r .reservation "$owner")
  assert_present "$reservation" "prepare did not atomically claim host capacity"
  [ "$(jq -r .accounting.next_action <<EOF
$(run_sandbox status "$ID_MAIN" --json)
EOF
)" = stage2-create-or-rollback ] || fail "prepared journal does not stop at the Stage 2 boundary"

  run_sandbox commit "$ID_MAIN" --sandbox-id stable-sandbox-001
  assert_lifecycle "$ID_MAIN" committed
  [ "$(jq -r .sandbox_id "$reservation")" = stable-sandbox-001 ] \
    || fail "reservation did not receive the immutable stable id"
  run_sandbox commit "$ID_MAIN" --sandbox-id stable-sandbox-001
  if run_sandbox commit "$ID_MAIN" --sandbox-id different-id >/dev/null 2>&1; then
    fail "commit allowed a stable sandbox id to change"
  fi

  receipt=$(run_sandbox cleanup-begin "$ID_MAIN" --json)
  [ "$(jq -r .sandbox_id <<EOF
$receipt
EOF
)" = stable-sandbox-001 ] || fail "cleanup receipt lost the stable sandbox id"
  assert_lifecycle "$ID_MAIN" cleanup_pending
  if run_sandbox cleanup-commit "$ID_MAIN" --sandbox-id wrong-stable-id >/dev/null 2>&1; then
    fail "cleanup accepted a stable sandbox id outside the ownership journal"
  fi
  assert_present "$(task_root "$ID_MAIN")/sandbox/workcopy" \
    "wrong cleanup identity removed the disposable clone"
  run_sandbox cleanup-commit "$ID_MAIN" --sandbox-id stable-sandbox-001
  assert_lifecycle "$ID_MAIN" cleaned
  assert_absent "$(task_root "$ID_MAIN")/sandbox" "cleanup left the disposable clone"
  assert_absent "$reservation" "cleanup left the exact host reservation"
  assert_present "$owner" "cleanup deleted machine-readable accounting"
  run_sandbox recover "$ID_MAIN" --json >/dev/null
  pass "fm-sandbox: immutable journal transitions and terminal cleanup are idempotent"
}

test_rollback_and_crash_recovery() {
  local owner reservation
  prepare_task "$ID_ROLLBACK" "$NONCE_ROLLBACK"
  reservation=$(jq -r .reservation "$(owner_path "$ID_ROLLBACK")")
  run_sandbox rollback "$ID_ROLLBACK"
  assert_lifecycle "$ID_ROLLBACK" rolled_back
  assert_absent "$(task_root "$ID_ROLLBACK")/sandbox" "rollback left the disposable clone"
  assert_absent "$reservation" "rollback left the exact host reservation"
  if run_sandbox commit "$ID_ROLLBACK" --sandbox-id impossible >/dev/null 2>&1; then
    fail "rolled-back ownership accepted a later sandbox id"
  fi

  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-journal \
      prepare_task "$ID_CRASH" "$NONCE_CRASH" >/dev/null 2>&1; then
    fail "prepare crash failpoint unexpectedly succeeded"
  fi
  owner=$(owner_path "$ID_CRASH")
  assert_lifecycle "$ID_CRASH" preparing
  assert_absent "$(jq -r .reservation "$owner")" "journal-first crash claimed capacity too early"
  run_sandbox recover "$ID_CRASH" --json >/dev/null
  assert_lifecycle "$ID_CRASH" rolled_back

  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-reservation \
      prepare_task "$ID_RESERVATION_CRASH" "$NONCE_RESERVATION_CRASH" >/dev/null 2>&1; then
    fail "reservation crash failpoint unexpectedly succeeded"
  fi
  owner=$(owner_path "$ID_RESERVATION_CRASH")
  assert_lifecycle "$ID_RESERVATION_CRASH" preparing
  assert_present "$(jq -r .reservation "$owner")" "reserved crash lost its capacity claim"
  run_sandbox recover "$ID_RESERVATION_CRASH" --json >/dev/null
  assert_lifecycle "$ID_RESERVATION_CRASH" rolled_back

  prepare_task "$ID_COMMIT_CRASH" "$NONCE_COMMIT_CRASH"
  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-commit-mark \
      run_sandbox commit "$ID_COMMIT_CRASH" --sandbox-id stable-crash-001 >/dev/null 2>&1; then
    fail "commit crash failpoint unexpectedly succeeded"
  fi
  assert_lifecycle "$ID_COMMIT_CRASH" commit_pending
  run_sandbox recover "$ID_COMMIT_CRASH" --json >/dev/null
  assert_lifecycle "$ID_COMMIT_CRASH" committed
  run_sandbox cleanup-begin "$ID_COMMIT_CRASH" >/dev/null
  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-cleanup-mark \
      run_sandbox cleanup-commit "$ID_COMMIT_CRASH" --sandbox-id stable-crash-001 >/dev/null 2>&1; then
    fail "cleanup crash failpoint unexpectedly succeeded"
  fi
  assert_lifecycle "$ID_COMMIT_CRASH" cleanup_finalizing
  run_sandbox recover "$ID_COMMIT_CRASH" --json >/dev/null
  assert_lifecycle "$ID_COMMIT_CRASH" cleaned

  prepare_task "$ID_CLEAN_LOCAL_CRASH" "$NONCE_CLEAN_LOCAL_CRASH"
  run_sandbox commit "$ID_CLEAN_LOCAL_CRASH" --sandbox-id stable-clean-local-001
  run_sandbox cleanup-begin "$ID_CLEAN_LOCAL_CRASH" >/dev/null
  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-cleanup-local-mark \
      run_sandbox cleanup-commit "$ID_CLEAN_LOCAL_CRASH" \
        --sandbox-id stable-clean-local-001 >/dev/null 2>&1; then
    fail "local cleanup crash failpoint unexpectedly succeeded"
  fi
  assert_lifecycle "$ID_CLEAN_LOCAL_CRASH" cleanup_releasing
  run_sandbox recover "$ID_CLEAN_LOCAL_CRASH" --json >/dev/null
  assert_lifecycle "$ID_CLEAN_LOCAL_CRASH" cleaned

  prepare_task "$ID_CLEAN_RELEASE_CRASH" "$NONCE_CLEAN_RELEASE_CRASH"
  run_sandbox commit "$ID_CLEAN_RELEASE_CRASH" --sandbox-id stable-clean-release-001
  run_sandbox cleanup-begin "$ID_CLEAN_RELEASE_CRASH" >/dev/null
  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-cleanup-release \
      run_sandbox cleanup-commit "$ID_CLEAN_RELEASE_CRASH" \
        --sandbox-id stable-clean-release-001 >/dev/null 2>&1; then
    fail "reservation release crash failpoint unexpectedly succeeded"
  fi
  assert_lifecycle "$ID_CLEAN_RELEASE_CRASH" cleanup_releasing
  run_sandbox recover "$ID_CLEAN_RELEASE_CRASH" --json >/dev/null
  assert_lifecycle "$ID_CLEAN_RELEASE_CRASH" cleaned

  prepare_task "$ID_ROLLBACK_CRASH" "$NONCE_ROLLBACK_CRASH"
  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-rollback-mark \
      run_sandbox rollback "$ID_ROLLBACK_CRASH" >/dev/null 2>&1; then
    fail "rollback crash failpoint unexpectedly succeeded"
  fi
  assert_lifecycle "$ID_ROLLBACK_CRASH" rollback_pending
  run_sandbox recover "$ID_ROLLBACK_CRASH" --json >/dev/null
  assert_lifecycle "$ID_ROLLBACK_CRASH" rolled_back
  pass "fm-sandbox: prepare, commit, rollback, and cleanup recover after bounded crash points"
}

test_atomic_capacity_and_path_custody() {
  local p1 p2 rc1=0 rc2=0 success_id target link_root linked_base
  prepare_task "$ID_CAP_A" "$NONCE_CAP_A" > "$TMP_ROOT/cap-a.out" 2>&1 &
  p1=$!
  prepare_task "$ID_CAP_B" "$NONCE_CAP_B" > "$TMP_ROOT/cap-b.out" 2>&1 &
  p2=$!
  wait "$p1" || rc1=$?
  wait "$p2" || rc2=$?
  if [ "$rc1" = 0 ] && [ "$rc2" != 0 ]; then
    success_id=$ID_CAP_A
  elif [ "$rc2" = 0 ] && [ "$rc1" != 0 ]; then
    success_id=$ID_CAP_B
  else
    fail "atomic maxConcurrent=1 claim produced rc1=$rc1 rc2=$rc2"
  fi
  run_sandbox rollback "$success_id"

  target="$TMP_ROOT/symlink-target"
  link_root=$(task_root "$ID_LINK")
  mkdir "$target"
  ln -s "$target" "$link_root"
  if prepare_task "$ID_LINK" "$NONCE_LINK" >/dev/null 2>&1; then
    fail "prepare accepted a symlinked task root"
  fi
  assert_absent "$(owner_path "$ID_LINK")" "symlink refusal published an ownership journal"
  assert_absent "$target/sandbox" "symlink refusal wrote through its target"
  rm -f "$link_root"

  linked_base="$TMP_ROOT/task-roots-link"
  ln -s "$TASK_BASE" "$linked_base"
  if FM_SANDBOX_TASK_ROOT_BASE="$linked_base" \
      run_sandbox prepare "$ID_LINK" --host dev --name "fm-$ID_LINK" --nonce "$NONCE_LINK" \
        --source "$SOURCE" --task-root "$linked_base/fm-$ID_LINK" >/dev/null 2>&1; then
    fail "prepare accepted a symlinked task-root base"
  fi
  pass "fm-sandbox: host capacity is atomic and task-root custody rejects symlinks"
}

test_task_transition_lock() {
  local p1 p2 rc1=0 rc2=0
  prepare_task "$ID_RACE" "$NONCE_RACE" > "$TMP_ROOT/race-a.out" 2>&1 &
  p1=$!
  prepare_task "$ID_RACE" "$NONCE_RACE" > "$TMP_ROOT/race-b.out" 2>&1 &
  p2=$!
  wait "$p1" || rc1=$?
  wait "$p2" || rc2=$?
  [ "$rc1" = 0 ] && [ "$rc2" = 0 ] \
    || fail "same-task prepare operations were not serialized (rc1=$rc1 rc2=$rc2)"
  assert_lifecycle "$ID_RACE" prepared
  run_sandbox rollback "$ID_RACE"
  pass "fm-sandbox: task lifecycle operations share a task-scoped lock"
}

test_incomplete_copy_recovery_and_missing_accounting() {
  local owner reservation workcopy out source_backup
  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-reservation \
      prepare_task "$ID_PARTIAL" "$NONCE_PARTIAL" >/dev/null 2>&1; then
    fail "partial-copy recovery setup unexpectedly succeeded"
  fi
  owner=$(owner_path "$ID_PARTIAL")
  workcopy="$(task_root "$ID_PARTIAL")/sandbox/workcopy"
  reservation=$(jq -r .reservation "$owner")
  mkdir "$(task_root "$ID_PARTIAL")/sandbox"
  git clone --quiet --no-local --no-hardlinks "$SOURCE" "$workcopy"
  rm -f "$workcopy/README.md"
  run_sandbox recover "$ID_PARTIAL" --json >/dev/null
  assert_lifecycle "$ID_PARTIAL" rolled_back
  assert_absent "$workcopy" "recovery promoted an incomplete disposable copy"
  assert_absent "$reservation" "recovery left the incomplete-copy reservation"

  prepare_task "$ID_MISSING" "$NONCE_MISSING"
  run_sandbox commit "$ID_MISSING" --sandbox-id stable-missing-001
  reservation=$(jq -r .reservation "$(owner_path "$ID_MISSING")")
  rm -f "$reservation"
  if run_sandbox cleanup-begin "$ID_MISSING" >/dev/null 2>&1; then
    fail "cleanup-begin accepted a missing reservation"
  fi
  assert_lifecycle "$ID_MISSING" committed
  out=$(run_sandbox status "$ID_MISSING" --json)
  [ "$(jq -r .accounting.reservation_present <<EOF
$out
EOF
)" = false ] || fail "status hid the missing reservation"
  [ "$(jq -r .accounting.next_action <<EOF
$out
EOF
)" = recover ] || fail "status did not require recovery for missing accounting"

  prepare_task "$ID_SOURCE_GONE" "$NONCE_SOURCE_GONE"
  source_backup="$TMP_ROOT/source-backup"
  mv "$SOURCE" "$source_backup"
  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-rollback-mark \
      run_sandbox rollback "$ID_SOURCE_GONE" >/dev/null 2>&1; then
    fail "source-disappearance crash setup unexpectedly succeeded"
  fi
  assert_lifecycle "$ID_SOURCE_GONE" rollback_pending
  run_sandbox recover "$ID_SOURCE_GONE" --json >/dev/null
  mv "$source_backup" "$SOURCE"
  assert_lifecycle "$ID_SOURCE_GONE" rolled_back

  prepare_task "$ID_SOURCE_REUSE" "$NONCE_SOURCE_REUSE"
  mv "$SOURCE" "$(task_root "$ID_SOURCE_REUSE")/sandbox/source"
  if run_sandbox rollback "$ID_SOURCE_REUSE" >/dev/null 2>&1; then
    fail "cleanup accepted a source tree moved inside the sandbox boundary"
  fi
  assert_lifecycle "$ID_SOURCE_REUSE" rollback_pending
  assert_present "$(task_root "$ID_SOURCE_REUSE")/sandbox/source" \
    "destructive cleanup removed a source tree moved inside the sandbox"
  assert_present "$(task_root "$ID_SOURCE_REUSE")/sandbox/workcopy" \
    "destructive cleanup removed the disposable copy before rejecting overlap"
  mv "$(task_root "$ID_SOURCE_REUSE")/sandbox/source" "$SOURCE"
  run_sandbox recover "$ID_SOURCE_REUSE" --json >/dev/null
  assert_lifecycle "$ID_SOURCE_REUSE" rolled_back

  if FM_SANDBOX_TEST_MODE=1 FM_SANDBOX_TEST_FAILPOINT=after-reservation \
      prepare_task "$ID_IGNORED" "$NONCE_IGNORED" >/dev/null 2>&1; then
    fail "ignored-file recovery setup unexpectedly succeeded"
  fi
  owner=$(owner_path "$ID_IGNORED")
  workcopy="$(task_root "$ID_IGNORED")/sandbox/workcopy"
  mkdir "$(task_root "$ID_IGNORED")/sandbox"
  git clone --quiet --no-local --no-hardlinks "$SOURCE" "$workcopy"
  printf '%s\n' 'ignored credential that must not survive custody validation' > "$workcopy/.env"
  run_sandbox recover "$ID_IGNORED" --json >/dev/null
  assert_lifecycle "$ID_IGNORED" rolled_back
  assert_absent "$workcopy" "recovery promoted a workcopy containing ignored files"
  pass "fm-sandbox: incomplete copies and missing cleanup accounting fail closed"
}

test_source_and_task_roots_do_not_overlap() {
  local equal_source="$TMP_ROOT/fm-$ID_EQUAL"
  fm_git_init_commit "$equal_source"
  if FM_SANDBOX_TASK_ROOT_BASE="$TMP_ROOT" run_sandbox prepare "$ID_EQUAL" \
      --host dev --name "fm-$ID_EQUAL" --nonce "$NONCE_EQUAL" \
      --source "$equal_source" --task-root "$equal_source" >/dev/null 2>&1; then
    fail "prepare accepted an equal source and task root"
  fi
  assert_absent "$(owner_path "$ID_EQUAL")" "equal-root refusal published a journal"
  assert_absent "$equal_source/sandbox" "equal-root refusal changed the source tree"
  if FM_SANDBOX_TASK_ROOT_BASE="$SOURCE" run_sandbox prepare "$ID_OVERLAP" \
      --host dev --name "fm-$ID_OVERLAP" --nonce "$NONCE_OVERLAP" \
      --source "$SOURCE" --task-root "$SOURCE/fm-$ID_OVERLAP" >/dev/null 2>&1; then
    fail "prepare accepted an overlapping source and task root"
  fi
  assert_absent "$(owner_path "$ID_OVERLAP")" "overlap refusal published a journal"
  assert_absent "$SOURCE/fm-$ID_OVERLAP" "overlap refusal created a task root"
  pass "fm-sandbox: source and task-root boundaries are disjoint before custody"
}

test_stage2_is_absent() {
  local sandbox spawn teardown
  sandbox=$(cat "$SCRIPT")
  spawn=$(cat "$ROOT/bin/fm-spawn.sh")
  teardown=$(cat "$ROOT/bin/fm-teardown.sh")
  assert_not_contains "$spawn" '--sandbox-host' "Stage 1 is wired into worker spawn"
  assert_not_contains "$teardown" 'fm-sandbox.sh' "Stage 1 is wired into task teardown"
  assert_not_contains "$sandbox" 'FM_SANDBOX_OPENAI_API_KEY' "Stage 1 accepts provider credentials"
  assert_not_contains "$sandbox" 'secret set' "Stage 1 injects sandbox secrets"
  assert_not_contains "$sandbox" 'lab-proof)' "Stage 1 exposes the deferred real proof"
  assert_not_contains "$sandbox" 'herdr ' "Stage 1 reaches Herdr or a default Herdr session"
  assert_not_contains "$sandbox" "\"\$SBX\" create" "Stage 1 creates a live microVM"
  assert_not_contains "$sandbox" "\"\$SBX\" run" "Stage 1 launches a worker"
  assert_not_contains "$sandbox" "\"\$SBX\" rm" "Stage 1 removes an external sandbox"
  assert_not_contains "$sandbox" 'docker run' "Stage 1 falls back to an ordinary container"
  assert_not_contains "$sandbox" '--privileged' "Stage 1 falls back to a privileged container"
  assert_not_contains "$sandbox" 'DOCKER_HOST' "Stage 1 accepts an ambient host Docker endpoint"
  assert_not_contains "$sandbox" '/var/run/docker.sock' "Stage 1 references the host Docker socket"
  assert_not_contains "$sandbox" '--mount' "Stage 1 mounts a host path"
  assert_not_contains "$sandbox" '/.ssh' "Stage 1 references host SSH state"
  assert_not_contains "$sandbox" '1Password' "Stage 1 references host 1Password state"
  assert_absent "$ROOT/tests/fm-sandbox-herdr-e2e.test.sh" "Stage 1 retained the Herdr proof"
  assert_absent "$ROOT/assets/sandbox-kits/firstmate-codex/spec.yaml" "Stage 1 retained an executable kit"
  # Assert the guarantee (the path is ignored), not the .gitignore bytes: a
  # broader rule such as "config/" satisfies this without naming each file.
  git -C "$ROOT" check-ignore -q config/sandbox-hosts.json ||
    fail "host inventory is not gitignored"
  git -C "$ROOT" check-ignore -q config/sandbox-workers-enabled ||
    fail "future rollout gate is not gitignored"
  pass "fm-sandbox: Stage 1 is inert and every worker, Herdr, credential, and live-sbx path is absent"
}

make_source
test_inventory_doctor_and_policy_contract
test_concurrent_coordination_initialization
test_prepare_commit_and_cleanup_journal
test_rollback_and_crash_recovery
test_atomic_capacity_and_path_custody
test_task_transition_lock
test_incomplete_copy_recovery_and_missing_accounting
test_source_and_task_roots_do_not_overlap
test_stage2_is_absent
