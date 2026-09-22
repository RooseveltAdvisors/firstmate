#!/usr/bin/env bash
# tests/fm-jev-stale-inbox-guard.test.sh - Verification suite for Pattern 228
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="${SCRIPT_DIR}/../bin/fm-jev-stale-inbox-guard.sh"
GUARD_PY="${SCRIPT_DIR}/../bin/fm-jev-stale-inbox-guard.py"

echo "=== Running fm-jev-stale-inbox-guard test suite ==="

# 1. Executable check
test -x "${GUARD_SH}" || { echo "FAIL: ${GUARD_SH} not executable"; exit 1; }
test -x "${GUARD_PY}" || { echo "FAIL: ${GUARD_PY} not executable"; exit 1; }
echo "PASS: Executable bits verified"

# 2. Help flag verification
"${GUARD_SH}" --help > /dev/null
echo "PASS: Help flag returns 0"

# 3. Live audit run
LIVE_JSON="$("${GUARD_SH}" --json 2>&1 || true)"
echo "${LIVE_JSON}" | grep -q '"status":' || { echo "FAIL: JSON output missing status"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"total_inboxes":' || { echo "FAIL: JSON output missing total_inboxes"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"total_unhandled_messages":' || { echo "FAIL: JSON output missing total_unhandled_messages"; exit 1; }
echo "PASS: Live audit returns valid schema"

# Temporary directory setup for synthetic tests
TMP_DIR="$(mktemp -d /tmp/fm-jev-inbox-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/state/dead-task.inbox"
mkdir -p "${TMP_DIR}/state/live-task.inbox"

# 4. Synthetic dead task with terminal status
cat << 'EOF' > "${TMP_DIR}/state/dead-task.status"
working [at=1790082000]: test
done [at=1790084000]: PR merged upstream
EOF

cat << 'EOF' > "${TMP_DIR}/state/dead-task.inbox/001.msg"
schema=fm-task-inbox.v1
at=2026-09-21T10:00:00Z
--
steer message to dead task
EOF

# Touch msg to make it 5 hours old
touch -d "5 hours ago" "${TMP_DIR}/state/dead-task.inbox/001.msg"

DEAD_AUDIT="$("${GUARD_SH}" --state-dir "${TMP_DIR}/state" --json 2>&1 || true)"
echo "${DEAD_AUDIT}" | grep -q '"stale_inboxes_count": 1' || { echo "FAIL: Expected stale_inboxes_count 1"; exit 1; }
echo "${DEAD_AUDIT}" | grep -q 'terminal_status' || { echo "FAIL: Expected dead task liveness reason terminal_status"; exit 1; }
echo "PASS: Dead task inbox accurately identified as stale"

# 5. Dry run does not move messages
DRY_AUDIT="$("${GUARD_SH}" --state-dir "${TMP_DIR}/state" --dry-run --drain-dead --json 2>&1 || true)"
echo "${DRY_AUDIT}" | grep -q '"drained_messages_count": 1' || { echo "FAIL: Expected dry-run to report 1 drained"; exit 1; }
test -f "${TMP_DIR}/state/dead-task.inbox/001.msg" || { echo "FAIL: dry-run moved the message"; exit 1; }
echo "PASS: Dry run leaves unhandled messages intact"

# 6. Drain dead endpoint moves message to handled/ and removes ring-state
touch "${TMP_DIR}/state/dead-task.inbox/.ring-state"
touch "${TMP_DIR}/state/dead-task.inbox/.escalated"

DRAIN_AUDIT="$("${GUARD_SH}" --state-dir "${TMP_DIR}/state" --drain-dead --json 2>&1 || true)"
echo "${DRAIN_AUDIT}" | grep -q '"drained_messages_count": 1' || { echo "FAIL: Expected 1 drained message"; exit 1; }
test ! -f "${TMP_DIR}/state/dead-task.inbox/001.msg" || { echo "FAIL: message was not removed from root"; exit 1; }
test -f "${TMP_DIR}/state/dead-task.inbox/handled/001.msg" || { echo "FAIL: message not moved to handled/"; exit 1; }
test ! -f "${TMP_DIR}/state/dead-task.inbox/.ring-state" || { echo "FAIL: ring-state was not removed"; exit 1; }
test ! -f "${TMP_DIR}/state/dead-task.inbox/.escalated" || { echo "FAIL: escalated marker was not removed"; exit 1; }
echo "PASS: Dead endpoint unhandled messages safely drained to handled/"

echo "=== All 6/6 tests passed successfully ==="
