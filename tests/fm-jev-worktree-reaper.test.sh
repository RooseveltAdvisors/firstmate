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

PROC_CLEAN="${TEST_TMP}/proc-clean"
mkdir -p "${PROC_CLEAN}/1000/fd"
ln -s / "${PROC_CLEAN}/1000/cwd"
printf 'Uid:\t1000\t1000\t1000\t1000\n' > "${PROC_CLEAN}/1000/status"

# Test 3: Dry run verifies identification without removing
DRY_OUTPUT=$("${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main --dry-run)
echo "${DRY_OUTPUT}" | grep -q "\[DRY_RUN\]"
test -d "${WT1}"
test -d "${WT2}"
echo "PASS: Test 3 - Dry run mode preserves all worktrees"

# Test 4: Live reap prunes merged worktree WT1 and strictly protects dirty WT2
LIVE_OUTPUT=$(FM_PROC_ROOT_OVERRIDE="${PROC_CLEAN}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
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
mkdir -p "${WT9}/sub"
READY_MARKER="${TEST_TMP}/wt9-ready"
( cd "${WT9}/sub" && : > "${READY_MARKER}" && exec sleep 300 ) &
SLEEP_PID=$!
trap 'kill "${SLEEP_PID}" 2>/dev/null || true; rm -rf "${TEST_TMP}"' EXIT
WAITED=0
while [ ! -e "${READY_MARKER}" ] && [ "${WAITED}" -lt 10 ]; do
  WAITED=$((WAITED + 1))
  sleep 1
done
test -e "${READY_MARKER}"
PROC9="${TEST_TMP}/proc-live"
mkdir -p "${PROC9}/${SLEEP_PID}/fd"
ln -s "${WT9}/sub" "${PROC9}/${SLEEP_PID}/cwd"
printf 'Uid:\t1000\t1000\t1000\t1000\n' > "${PROC9}/${SLEEP_PID}/status"
PROC_OUTPUT=$(FM_PROC_ROOT_OVERRIDE="${PROC9}" FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${PROC_OUTPUT}" | grep -q "Referenced: ${WT9} (running process"
test -d "${WT9}"
kill "${SLEEP_PID}" 2>/dev/null || true
wait "${SLEEP_PID}" 2>/dev/null || true
trap 'rm -rf "${TEST_TMP}"' EXIT
echo "PASS: Test 9 - worktree with a running process preserved"

# Test 10 (fm-av46m): an unreferenced merged clean worktree is still reaped
WT10="${TEST_TMP}/wt-unreferenced"
git -C "${REPO}" worktree add --detach "${WT10}" main
REAP_OUTPUT=$(FM_PROC_ROOT_OVERRIDE="${PROC_CLEAN}" FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${REAP_OUTPUT}" | grep -q "Reaped: ${WT10} "
if [ -d "${WT10}" ]; then
  echo "FAIL: unreferenced merged worktree WT10 was not removed" >&2
  exit 1
fi
echo "PASS: Test 10 - unreferenced merged worktree still reaped"

# Test 11 (fm-av46m): a registry record whose scope prose contains a decoy
# "(home: ...;" still contributes its real home
WT11="${TEST_TMP}/wt-registry-referenced"
git -C "${REPO}" worktree add --detach "${WT11}" main
SECOND_HOME="${TEST_TMP}/secondmate-home"
mkdir -p "${SECOND_HOME}/state" "${FAKE_HOME}/data"
printf 'worktree=%s\n' "${WT11}" > "${SECOND_HOME}/state/fm-real-task.meta"
printf -- '- sm-one - worker (home:\t%s; scope: retired (home: /decoy; legacy) audits; projects: p1; added 2024-01-01)\n' "${SECOND_HOME}" > "${FAKE_HOME}/data/secondmates.md"
REG_OUTPUT=$(FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${REG_OUTPUT}" | grep -q "Referenced: ${WT11} (task record fm-real-task"
test -d "${WT11}"
echo "PASS: Test 11 - decoy home text in registry scope prose cannot hide a real home"

# Test 12 (fm-av46m): a reference source that cannot be read keeps every worktree
WT12="${TEST_TMP}/wt-scan-inconclusive"
git -C "${REPO}" worktree add --detach "${WT12}" main
chmod 000 "${FAKE_HOME}/data/secondmates.md"
SCAN_OUTPUT=$(FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${SCAN_OUTPUT}" | grep -q "Referenced: ${WT12} (reference scan inconclusive"
test -d "${WT12}"
echo "PASS: Test 12 - unreadable reference source preserves worktrees"
chmod 644 "${FAKE_HOME}/data/secondmates.md"

# Test 13 (fm-av46m): an open file inside a merged clean worktree preserves it
WT13="${TEST_TMP}/wt-fd-referenced"
git -C "${REPO}" worktree add --detach "${WT13}" main
mkdir -p "${WT13}/open"
PROC13="${TEST_TMP}/proc-fd"
mkdir -p "${PROC13}/5150/fd"
ln -s / "${PROC13}/5150/cwd"
ln -s "${WT13}/open" "${PROC13}/5150/fd/7"
printf 'Uid:\t1000\t1000\t1000\t1000\n' > "${PROC13}/5150/status"
FD_OUTPUT=$(FM_PROC_ROOT_OVERRIDE="${PROC13}" FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${FD_OUTPUT}" | grep -q "Referenced: ${WT13} (running process"
test -d "${WT13}"
echo "PASS: Test 13 - worktree with an open file preserved"

# Test 14 (fm-av46m): an unreadable pid is doubt and refuses the reap
WT14="${TEST_TMP}/wt-probe-doubt"
git -C "${REPO}" worktree add --detach "${WT14}" main
PROC14="${TEST_TMP}/proc-doubt"
mkdir -p "${PROC14}/777/cwd" "${PROC14}/777/fd"
printf 'Uid:\t0\t0\t0\t0\n' > "${PROC14}/777/status"
DOUBT_OUTPUT=$(FM_PROC_ROOT_OVERRIDE="${PROC14}" FM_HOME="${FAKE_HOME}" "${REAPER_WRAPPER}" --repo-dir "${REPO}" --base-branch main)
echo "${DOUBT_OUTPUT}" | grep -q "process probe inconclusive (unreadable pid 777 uid 0)"
test -d "${WT14}"
echo "PASS: Test 14 - unreadable pid refuses the reap with uid and pid detail"

echo "=== All 14 fm-jev-worktree-reaper tests passed successfully! ==="
