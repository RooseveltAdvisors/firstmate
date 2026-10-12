#!/usr/bin/env bash
# tests/fm-jev-done-verify.test.sh - verify Jev Definition of Done & Fake-Done Verifier
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY_SH="$ROOT/bin/fm-jev-done-verify.sh"
VERIFY_PY="$ROOT/bin/fm-jev-done-verify.py"

[ -x "$VERIFY_SH" ] || fail "bin/fm-jev-done-verify.sh missing or not executable"
[ -x "$VERIFY_PY" ] || fail "bin/fm-jev-done-verify.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-done-test)

# 1. Ephemeral residue rejection
set +e
out_ephem=$("$VERIFY_SH" --task "test-task" --status-line "done: transcription works via temporary relay on port 8000" 2>&1)
rc_ephem=$?
set -e
[ "$rc_ephem" -eq 2 ] || fail "ephemeral relay status was not rejected (got exit $rc_ephem)"
assert_contains "$out_ephem" "rejected [ephemeral_relay]" "detected ephemeral relay"

# 2. Dirty worktree rejection
WT_DIR="$TDIR/dirty-wt"
fm_git_identity fmtest fmtest@example.invalid
git init -q "$WT_DIR"
git -C "$WT_DIR" commit -q --allow-empty -m "initial commit"
echo "uncommitted changes" > "$WT_DIR/dirty.txt"

set +e
out_dirty=$("$VERIFY_SH" --task "dirty-task" --worktree "$WT_DIR" --status-line "done: all tests passing" 2>&1)
rc_dirty=$?
set -e
[ "$rc_dirty" -eq 2 ] || fail "dirty worktree was not rejected (got exit $rc_dirty)"
assert_contains "$out_dirty" "rejected [dirty_worktree]" "detected dirty worktree"

# 3. Clean deliverable verification passes
out_clean=$("$VERIFY_SH" --task "fm-claimmd-billing" --status-line "done: PR https://github.com/ArcsHealth/Portal/pull/1751 checks green" 2>&1)
assert_contains "$out_clean" "VERDICT: verified" "clean task verified"

# 4. Unpushed branch rejection (Tier 1)
set +e
out_unpushed=$("$VERIFY_SH" --task "fm-uiq-dup-merge" --status-line "done: dry-run committed on branch fm/fm-uiq-dup-merge" 2>&1)
rc_unpushed=$?
set -e
[ "$rc_unpushed" -eq 2 ] || fail "unpushed commits were not rejected (got exit $rc_unpushed)"
assert_contains "$out_unpushed" "rejected [unpushed_commits]" "detected unpushed commits"

pass "all fm-jev-done-verify tests passed"
