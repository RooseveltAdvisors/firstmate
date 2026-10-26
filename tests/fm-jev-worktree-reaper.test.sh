#!/usr/bin/env bash
# tests/fm-jev-worktree-reaper.test.sh - Regression test suite for Pattern 19
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAPER_ENGINE="${FM_ROOT}/bin/fm-jev-worktree-reaper.py"
REAPER_WRAPPER="${FM_ROOT}/bin/fm-jev-worktree-reaper.sh"

echo "=== Running fm-jev-worktree-reaper test suite ==="

# Test 1: Python syntax compilation
python3 -m py_compile "${REAPER_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${REAPER_WRAPPER}"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Setup temporary test repository
TEST_TMP=$(mktemp -d)
trap 'rm -rf "${TEST_TMP}"' EXIT

REPO="${TEST_TMP}/repo"
mkdir -p "${REPO}"
git -C "${REPO}" init -b main
git -C "${REPO}" config user.name "Test User"
git -C "${REPO}" config user.email "test@example.com"
echo "init" > "${REPO}/README.md"
git -C "${REPO}" add README.md
git -C "${REPO}" commit -m "init"

# Create worktree 1: merged worktree
git -C "${REPO}" branch merged-feature
WT1="${TEST_TMP}/wt-merged"
git -C "${REPO}" worktree add "${WT1}" merged-feature
echo "feature" > "${WT1}/feature.txt"
git -C "${WT1}" add feature.txt
git -C "${WT1}" commit -m "feature commit"
git -C "${REPO}" merge --no-ff merged-feature -m "merge feature"

# Create worktree 2: dirty worktree
git -C "${REPO}" branch dirty-feature
WT2="${TEST_TMP}/wt-dirty"
git -C "${REPO}" worktree add "${WT2}" dirty-feature
echo "uncommitted change" >> "${WT2}/dirty.txt"

# Test 3: Dry run verifies identification without removing
DRY_OUTPUT=$("${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main --dry-run)
echo "${DRY_OUTPUT}" | grep -q "\[DRY_RUN\]"
test -d "${WT1}"
test -d "${WT2}"
echo "PASS: Test 3 - Dry run mode preserves all worktrees"

# Test 4: Live reap prunes merged worktree WT1 and strictly protects dirty WT2
LIVE_OUTPUT=$("${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${LIVE_OUTPUT}" | grep -q "\[REAPER_APPLIED\]"
if [ -d "${WT1}" ]; then
  echo "FAIL: merged worktree WT1 was not removed" >&2
  exit 1
fi
if [ ! -d "${WT2}" ]; then
  echo "FAIL: dirty worktree WT2 was incorrectly removed!" >&2
  exit 1
fi
echo "PASS: Test 4 - Live reap removed merged worktree and preserved dirty worktree"

# Test 5: JSON output telemetry
JSON_OUTPUT=$("${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main --json)
python3 -c "import json; d = json.loads('''${JSON_OUTPUT}'''); assert 'dirty_preserved' in d; assert d['dirty_preserved'] == 1"
echo "PASS: Test 5 - JSON telemetry output validated"

# Test 6 (fm-av46m): a merged clean worktree named by a task record is preserved
WT6="${TEST_TMP}/wt-task-referenced"
git -C "${REPO}" worktree add --detach "${WT6}" main
FAKE_HOME="${TEST_TMP}/fm-home"
mkdir -p "${FAKE_HOME}/state"
printf 'worktree=%s\n' "${WT6}" > "${FAKE_HOME}/state/fm-test-task.meta"
REF_OUTPUT=$(FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${REF_OUTPUT}" | grep -q "Referenced: ${WT6} (task record fm-test-task"
test -d "${WT6}"
echo "PASS: Test 6 - task-recorded worktree preserved"

# Test 7 (fm-av46m): a nested clone under a task-recorded slot is preserved
SLOT="${TEST_TMP}/slot-parent"
WT7="${SLOT}/wt-nested"
mkdir -p "${SLOT}"
git -C "${REPO}" worktree add --detach "${WT7}" main
printf 'worktree=%s\n' "${SLOT}" > "${FAKE_HOME}/state/fm-slot-task.meta"
NESTED_OUTPUT=$(FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${NESTED_OUTPUT}" | grep -q "Referenced: ${WT7} "
test -d "${WT7}"
echo "PASS: Test 7 - nested clone under a task-recorded slot preserved"

# Test 8 (fm-av46m): a durable treehouse lease on a merged clean worktree preserves it
WT8="${TEST_TMP}/wt-leased"
git -C "${REPO}" worktree add --detach "${WT8}" main
FAKE_USER_HOME="${TEST_TMP}/user-home"
mkdir -p "${FAKE_USER_HOME}/.treehouse/pool-test"
python3 - "${WT8}" "${FAKE_USER_HOME}/.treehouse/pool-test/treehouse-state.json" <<'EOF'
import json, sys
path, state = sys.argv[1], sys.argv[2]
json.dump({"version": 1, "worktrees": [{"name": "1", "path": path, "leased": True,
          "lease_id": "abc123", "lease_holder": "test-lease-holder"}]}, open(state, "w"))
EOF
LEASE_OUTPUT=$(HOME="${FAKE_USER_HOME}" FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${LEASE_OUTPUT}" | grep -q "Referenced: ${WT8} (treehouse lease held by test-lease-holder)"
test -d "${WT8}"
echo "PASS: Test 8 - treehouse-leased worktree preserved"

# Test 9 (fm-av46m): a running process inside a merged clean worktree preserves it
WT9="${TEST_TMP}/wt-live-process"
git -C "${REPO}" worktree add --detach "${WT9}" main
( cd "${WT9}" && exec sleep 300 ) &
SLEEP_PID=$!
trap 'kill "${SLEEP_PID}" 2>/dev/null || true; rm -rf "${TEST_TMP}"' EXIT
PROC_OUTPUT=$(FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${PROC_OUTPUT}" | grep -q "Referenced: ${WT9} (running process"
test -d "${WT9}"
kill "${SLEEP_PID}" 2>/dev/null || true
wait "${SLEEP_PID}" 2>/dev/null || true
trap 'rm -rf "${TEST_TMP}"' EXIT
echo "PASS: Test 9 - worktree with a running process preserved"

# Test 10 (fm-av46m): an unreferenced merged clean worktree is still reaped
WT10="${TEST_TMP}/wt-unreferenced"
git -C "${REPO}" worktree add --detach "${WT10}" main
REAP_OUTPUT=$(FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${REAP_OUTPUT}" | grep -q "Reaped: ${WT10} "
if [ -d "${WT10}" ]; then
  echo "FAIL: unreferenced merged worktree WT10 was not removed" >&2
  exit 1
fi
echo "PASS: Test 10 - unreferenced merged worktree still reaped"

echo "=== All 10 fm-jev-worktree-reaper tests passed successfully! ==="
