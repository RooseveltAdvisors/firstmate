#!/usr/bin/env bash
# Behavior tests for the ship-done acceptance gate (bin/fm-done-guard.sh).
# A PR-requiring ship may report done only after HEAD is on origin and an open
# PR is referenced. Tests drive the public check/apply CLI, never implementation
# source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-done-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-done-guard)

make_ship() {  # <name> <mode> <kind>
  local name=$1 mode=$2 kind=${3:-ship} home wt branch
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/data"
  branch="fm/${name}"
  fm_git_worktree "$TMP_ROOT/$name/repo" "$TMP_ROOT/$name/wt" "$branch"
  wt="$TMP_ROOT/$name/wt"
  fm_write_meta "$home/state/${name}.meta" \
    "window=test:fm-${name}" \
    "worktree=$wt" \
    "kind=$kind" \
    "mode=$mode"
  printf '%s\n' "$home|$wt|$branch"
}

commit_on() {  # <worktree> <file> <message>
  local wt=$1 file=$2 msg=$3
  printf 'x\n' >> "$wt/$file"
  git -C "$wt" add "$file"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$msg"
}

run_check() {  # <home> <id>
  local home=$1 id=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$GUARD" check "$id"
}

run_apply() {  # <home> <id>
  local home=$1 id=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DONE_GUARD_SEND="$home/fake-send" "$GUARD" apply "$id"
}

install_fake_send() {  # <home>
  local home=$1
  cat > "$home/fake-send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_DONE_GUARD_SEND_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$home/fake-send"
}

test_unpushed_commit_refuses_done() {
  local rec home wt id=unpushed-a1 out rc
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "local only"
  printf 'done: implementation complete\n' > "$home/state/${id}.status"
  out=$(run_check "$home" "$id") || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 1 ] || fail "unpushed ship done should be refused, got exit $rc ($out)"
  assert_contains "$out" "verdict=refused" "unpushed ship did not print refused"
  assert_contains "$out" "reason=unpushed" "unpushed ship did not name the unpushed reason"
  pass "worker commits but does not push -> done refused"
}

test_pushed_without_pr_refuses_done() {
  local rec home wt branch id=pushed-nopr-a1 out rc
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "ready"
  git -C "$wt" push -q -u origin "$branch"
  printf 'done: implementation complete\n' > "$home/state/${id}.status"
  rc=0
  out=$(FM_DONE_GUARD_NO_FORGE=1 run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "pushed ship without a PR should be refused, got exit $rc ($out)"
  assert_contains "$out" "verdict=refused" "pushed no-PR ship did not print refused"
  assert_contains "$out" "reason=no-pr" "pushed no-PR ship did not name the no-pr reason"
  pass "worker pushes but opens no PR -> done refused for ship tasks"
}

test_pushed_with_pr_accepts_done() {
  local rec home wt branch id=pushed-pr-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "ready"
  git -C "$wt" push -q -u origin "$branch"
  printf 'done: PR https://github.com/example/repo/pull/7 checks green\n' \
    > "$home/state/${id}.status"
  out=$(run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "pushed ship with a PR URL should be accepted, got exit $rc ($out)"
  assert_contains "$out" "verdict=accepted" "pushed+PR ship did not print accepted"
  pass "worker pushes and opens a PR -> done accepted"
}

test_scout_and_local_only_skip() {
  local rec home wt id out rc
  id=scout-skip-a1
  rec=$(make_ship "$id" scout scout)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" notes.txt "findings"
  printf 'done: report complete\n' > "$home/state/${id}.status"
  rc=0
  out=$(run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "scout done should be skipped, got exit $rc ($out)"
  assert_contains "$out" "verdict=skipped" "scout did not skip the PR requirement"

  id=local-skip-a1
  rec=$(make_ship "$id" local-only)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "local"
  printf 'done: ready in branch fm/%s\n' "$id" > "$home/state/${id}.status"
  rc=0
  out=$(run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "local-only done should be skipped, got exit $rc ($out)"
  assert_contains "$out" "verdict=skipped" "local-only did not skip the PR requirement"
  pass "scout and local-only dones are skipped"
}

test_span_drops_refused_done() {
  local rec home wt id=span-drop-a1 event rc
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "local only"
  printf 'done: implementation complete\n' > "$home/state/${id}.status"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-done-guard-lib.sh"
  rc=0
  event=$(status_span_first_actionable "$home/state/${id}.status" 0) || rc=$?
  [ "$rc" -eq 1 ] || fail "refused done span should not be actionable, got rc=$rc event='$event'"
  [ -z "$event" ] || fail "refused done span leaked an event: $event"
  pass "classifier drops a refused ship done from the actionable span"
}

test_apply_steers_on_refuse() {
  local rec home wt id=steer-a1 out rc log
  rec=$(make_ship "$id" direct-PR)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  install_fake_send "$home"
  log="$home/send.log"
  commit_on "$wt" feature.txt "local only"
  printf 'done: ready\n' > "$home/state/${id}.status"
  rc=0
  out=$(FM_DONE_GUARD_SEND_LOG="$log" run_apply "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "apply on unpushed ship should refuse, got exit $rc ($out)"
  [ -s "$log" ] || fail "refused done did not steer the worker"
  assert_contains "$(cat "$log")" "$id" "steer did not name the task"
  assert_contains "$(cat "$log")" "pushed branch" "steer did not tell the worker to push"
  pass "apply refuses an unpushed done and steers the worker to push"
}

test_unpushed_commit_refuses_done
test_pushed_without_pr_refuses_done
test_pushed_with_pr_accepts_done
test_scout_and_local_only_skip
test_span_drops_refused_done
test_apply_steers_on_refuse
