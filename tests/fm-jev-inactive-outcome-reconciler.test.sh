#!/usr/bin/env bash
# tests/fm-jev-inactive-outcome-reconciler.test.sh - Verification suite for Pattern 226
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILER_SH="${SCRIPT_DIR}/../bin/fm-jev-inactive-outcome-reconciler.sh"
RECONCILER_PY="${SCRIPT_DIR}/../bin/fm-jev-inactive-outcome-reconciler.py"

echo "=== Running fm-jev-inactive-outcome-reconciler test suite ==="

# 1. Executable check
test -x "${RECONCILER_SH}" || { echo "FAIL: ${RECONCILER_SH} not executable"; exit 1; }
test -x "${RECONCILER_PY}" || { echo "FAIL: ${RECONCILER_PY} not executable"; exit 1; }
echo "PASS: Executable bits verified"

# 2. Help flag verification
"${RECONCILER_SH}" --help > /dev/null
echo "PASS: Help flag returns 0"

# 3. Live audit run
LIVE_JSON="$("${RECONCILER_SH}" --json)"
echo "${LIVE_JSON}" | grep -q '"status":' || { echo "FAIL: JSON output missing status"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"pending_count":' || { echo "FAIL: JSON output missing pending_count"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"reconciled_count":' || { echo "FAIL: JSON output missing reconciled_count"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"retained_count":' || { echo "FAIL: JSON output missing retained_count"; exit 1; }
echo "PASS: Live audit returns valid schema"

# Temporary directory setup for synthetic tests
TMP_DIR="$(mktemp -d /tmp/fm-jev-inactive-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/state/terminal-outcomes"

# 4. Active/unresolved task should NOT be auto-reconciled
cat << 'EOF' > "${TMP_DIR}/state/task-active.status"
working [at=1790082000]: running tests
blocked [at=1790083000]: waiting on database migration
EOF

cat << 'EOF' > "${TMP_DIR}/state/terminal-outcomes/active0123456789abcdef0123456789ab.pending"
schema=fm-terminal-outcome.v1
fingerprint=active0123456789abcdef0123456789ab
task_id=task-active
state=blocked
phase=presentation
EOF

ACTIVE_OUT="$("${RECONCILER_SH}" --state-dir "${TMP_DIR}/state" --json)"
echo "${ACTIVE_OUT}" | grep -q '"pending_count": 1' || { echo "FAIL: Expected pending_count 1"; exit 1; }
echo "${ACTIVE_OUT}" | grep -q '"reconciled_count": 0' || { echo "FAIL: Expected reconciled_count 0 for active task"; exit 1; }
echo "${ACTIVE_OUT}" | grep -q '"retained_count": 1' || { echo "FAIL: Expected retained_count 1 for active task"; exit 1; }
test -f "${TMP_DIR}/state/terminal-outcomes/active0123456789abcdef0123456789ab.pending" || { echo "FAIL: active pending file was prematurely removed"; exit 1; }
echo "PASS: Unresolved task pending outcome preserved"

# 5. Done task with terminal status ledger is automatically reconciled to .presented
cat << 'EOF' > "${TMP_DIR}/state/task-done.status"
working [at=1790082000]: running implementation
done [at=1790084000]: PR https://github.com/RooseveltAdvisors/repo/pull/1 merged upstream
EOF

cat << 'EOF' > "${TMP_DIR}/state/terminal-outcomes/done0123456789abcdef0123456789abc.pending"
schema=fm-terminal-outcome.v1
fingerprint=done0123456789abcdef0123456789abc
task_id=task-done
state=done
phase=presentation
EOF

RECON_OUT="$("${RECONCILER_SH}" --state-dir "${TMP_DIR}/state" --json)"
echo "${RECON_OUT}" | grep -q '"reconciled_count": 1' || { echo "FAIL: Expected reconciled_count 1 for done task"; exit 1; }
test -f "${TMP_DIR}/state/terminal-outcomes/done0123456789abcdef0123456789abc.presented" || { echo "FAIL: presented file not created"; exit 1; }
test ! -f "${TMP_DIR}/state/terminal-outcomes/done0123456789abcdef0123456789abc.pending" || { echo "FAIL: pending file still exists after reconciliation"; exit 1; }
echo "PASS: Terminal done task auto-reconciled to presented"

# 6. Dry run leaves pending file untouched while reporting eligibility
cat << 'EOF' > "${TMP_DIR}/state/task-dryrun.status"
done [at=1790085000]: shipped and verified
EOF

cat << 'EOF' > "${TMP_DIR}/state/terminal-outcomes/dry0123456789abcdef0123456789abcd.pending"
schema=fm-terminal-outcome.v1
fingerprint=dry0123456789abcdef0123456789abcd
task_id=task-dryrun
state=done
phase=presentation
EOF

DRY_OUT="$("${RECONCILER_SH}" --state-dir "${TMP_DIR}/state" --dry-run --json)"
echo "${DRY_OUT}" | grep -q '"reconciled_count": 1' || { echo "FAIL: Expected dry-run to report 1 eligible"; exit 1; }
test -f "${TMP_DIR}/state/terminal-outcomes/dry0123456789abcdef0123456789abcd.pending" || { echo "FAIL: dry-run modified the pending file"; exit 1; }
echo "PASS: Dry run preserves pending files while verifying eligibility"

echo "=== All 6/6 tests passed successfully ==="
