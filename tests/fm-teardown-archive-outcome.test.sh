#!/usr/bin/env bash
# Executable regression for teardown's durable outcome archive gate.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-archive-outcome)
ID=archive-task
DONE='done [at=1791211800]: PR https://github.com/example/repo/pull/401 merge_sha=0123456789012345678901234567890123456789 workflows=CI sync=2026-10-05T14:50:00Z live=green'
LATE='done [at=1791211801]: PR https://github.com/example/repo/pull/401 merge_sha=0123456789012345678901234567890123456789 workflows=CI sync=2026-10-05T14:50:01Z live=green'

make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/fakebin"
  fm_write_meta "$dir/state/$ID.meta" "kind=ship" "mode=local-only" \
    "window=isolated:fm-$ID" "endpoint_task_id=$ID" \
    "worktree=$dir/missing-worktree" "project=$dir/missing-project"
  printf '%s\n' "$DONE" > "$dir/state/$ID.status"
  printf 'turn-ended\n' > "$dir/state/$ID.turn-ended"
  printf 'progress\n' > "$dir/state/$ID.progress"
  touch "$dir/state/.last-watcher-beat"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/no-mistakes"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = kill-window ]; then
  if [ -e "$FM_HOME/append-after-close" ]; then
    cat "$FM_HOME/late-status" >> "$FM_HOME/state/archive-task.status"
    rm -f "$FM_HOME/append-after-close"
  fi
  if [ -e "$FM_HOME/fail-after-close" ]; then
    touch "$FM_HOME/endpoint-closed"
    rm -rf "$FM_HOME/data/archive-task"
    ln -s "$FM_HOME/outside" "$FM_HOME/data/archive-task"
  fi
fi
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

run_case() {
  FM_TEARDOWN_GUARD_DONE=1 FM_DISABLE_JEV_WORKTREE_REAPER=1 \
  FM_DISABLE_JEV_PANE_REAPER=1 FM_DISABLE_JEV_ARTIFACT_DEDUP=1 \
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" PATH="$1/fakebin:$PATH" \
    bash "$ROOT/bin/fm-teardown.sh" "$ID"
}

dir=$(make_case success)
cp "$dir/state/$ID.status" "$dir/expected"
run_case "$dir" > "$dir/out" 2> "$dir/err" || fail "archive teardown failed: $(cat "$dir/err")"
assert_present "$dir/data/$ID/outcome.md" "outcome did not survive teardown"
cmp -s "$dir/expected" "$dir/data/$ID/outcome.md" || fail "done line was not archived byte-for-byte"
assert_absent "$dir/state/$ID.status" "teardown left the status file"
pass "fm-teardown archive: fake task tears down and its exact done line survives"

dir=$(make_case append-after-close)
printf '%s\n' "$LATE" > "$dir/late-status"
touch "$dir/append-after-close"
printf '%s\n' "$DONE" "$LATE" > "$dir/expected"
run_case "$dir" > "$dir/out" 2> "$dir/err" || fail "late append teardown failed: $(cat "$dir/err")"
cmp -s "$dir/expected" "$dir/data/$ID/outcome.md" || fail "late status append was not archived"
pass "fm-teardown archive: status appended after endpoint close is preserved"

dir=$(make_case failure-after-close)
mkdir -p "$dir/outside"
printf '# check artifact\n' > "$dir/state/$ID.check.sh"
touch "$dir/fail-after-close"
if run_case "$dir" > "$dir/out" 2> "$dir/err"; then
  fail "post-close archive failure unexpectedly allowed teardown"
fi
assert_present "$dir/endpoint-closed" "archive failure was not reached after endpoint close"
assert_present "$dir/state/$ID.meta" "post-close archive failure removed metadata"
assert_present "$dir/state/$ID.status" "post-close archive failure removed status"
assert_present "$dir/state/$ID.check.sh" "post-close archive failure removed PR-check state"
assert_present "$dir/state/$ID.turn-ended" "post-close archive failure removed turn-ended state"
assert_present "$dir/state/$ID.progress" "post-close archive failure removed progress state"
[ -L "$dir/data/$ID" ] || fail "post-close archive failure replaced the unsafe outcome directory"
assert_absent "$dir/outside/outcome.md" "post-close archive failure published outside the data home"
pass "fm-teardown archive: post-close failure preserves root state"

dir=$(make_case unwritable)
mkdir -p "$dir/data/$ID"
chmod 500 "$dir/data/$ID"
if run_case "$dir" > "$dir/out" 2> "$dir/err"; then
  chmod 700 "$dir/data/$ID"
  fail "unwritable archive unexpectedly allowed teardown"
fi
chmod 700 "$dir/data/$ID"
assert_present "$dir/state/$ID.meta" "archive failure removed metadata"
assert_present "$dir/state/$ID.status" "archive failure removed status"
assert_present "$dir/state/$ID.turn-ended" "archive failure removed turn-ended"
assert_present "$dir/state/$ID.progress" "archive failure removed progress"
assert_absent "$dir/data/$ID/outcome.md" "failed archive unexpectedly exists"
pass "fm-teardown archive: unwritable destination refuses with all task state present"

for source in empty shorter missing; do
  dir=$(make_case "$source")
  mkdir -p "$dir/data/$ID"
  cp "$dir/state/$ID.status" "$dir/data/$ID/outcome.md"
  cp "$dir/state/$ID.status" "$dir/expected"
  case "$source" in
    empty) : > "$dir/state/$ID.status" ;;
    shorter) printf 'done\n' > "$dir/state/$ID.status" ;;
    missing) rm "$dir/state/$ID.status" ;;
  esac
  run_case "$dir" > "$dir/out" 2> "$dir/err" || fail "$source retry failed: $(cat "$dir/err")"
  cmp -s "$dir/expected" "$dir/data/$ID/outcome.md" || fail "$source retry clobbered the outcome"
  pass "fm-teardown archive: $source status preserves the longer existing outcome"
done

dir=$(make_case symlink-status)
printf '%s\n' "$DONE" > "$dir/private-status"
rm "$dir/state/$ID.status"
ln -s "$dir/private-status" "$dir/state/$ID.status"
if run_case "$dir" > "$dir/out" 2> "$dir/err"; then
  fail "symlinked status unexpectedly allowed teardown"
fi
[ -L "$dir/state/$ID.status" ] || fail "symlinked status was removed"
assert_absent "$dir/data/$ID/outcome.md" "symlinked status unexpectedly created an outcome"
pass "fm-teardown archive: symlinked status is refused without publishing its target"

dir=$(make_case symlink-data-dir)
outside="$dir/outside"
mkdir -p "$outside"
rm -rf "$dir/data/$ID"
ln -s "$outside" "$dir/data/$ID"
if run_case "$dir" > "$dir/out" 2> "$dir/err"; then
  fail "symlinked outcome directory unexpectedly allowed teardown"
fi
[ -L "$dir/data/$ID" ] || fail "symlinked outcome directory was removed"
assert_absent "$outside/outcome.md" "unsafe outcome directory received an archive"
pass "fm-teardown archive: symlinked outcome directory is refused before publication"

dir=$(make_case symlink-outcome)
outside="$dir/outside"
mkdir -p "$dir/data/$ID" "$outside"
printf 'outside\n' > "$outside/outcome.md"
ln -s "$outside/outcome.md" "$dir/data/$ID/outcome.md"
if run_case "$dir" > "$dir/out" 2> "$dir/err"; then
  fail "symlinked outcome unexpectedly allowed teardown"
fi
cmp -s <(printf 'outside\n') "$outside/outcome.md" || fail "unsafe outcome target was modified"
pass "fm-teardown archive: symlinked outcome is refused before publication"
