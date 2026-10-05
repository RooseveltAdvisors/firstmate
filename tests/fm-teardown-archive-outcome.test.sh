#!/usr/bin/env bash
# Executable regression for teardown's durable outcome archive gate.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-archive-outcome)
ID=archive-task
DONE='done [at=1791211800]: PR https://github.com/example/repo/pull/401 merge_sha=0123456789012345678901234567890123456789 workflows=CI sync=2026-10-05T14:50:00Z live=green'

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
