#!/usr/bin/env bash
# tests/fm-jev-tcp-mem-guard.test.sh - Verification suite for Pattern 223
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="${SCRIPT_DIR}/../bin/fm-jev-tcp-mem-guard.sh"
GUARD_PY="${SCRIPT_DIR}/../bin/fm-jev-tcp-mem-guard.py"

echo "=== Running fm-jev-tcp-mem-guard test suite ==="

# 1. Executable check
test -x "${GUARD_SH}" || { echo "FAIL: ${GUARD_SH} not executable"; exit 1; }
test -x "${GUARD_PY}" || { echo "FAIL: ${GUARD_PY} not executable"; exit 1; }
echo "PASS: Executable bits verified"

# 2. Help flag verification
"${GUARD_SH}" --help > /dev/null
echo "PASS: Help flag returns 0"

# 3. Live audit run
LIVE_JSON="$("${GUARD_SH}" --json)"
echo "${LIVE_JSON}" | grep -q '"status":' || { echo "FAIL: JSON output missing status"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"tcp_memory":' || { echo "FAIL: JSON output missing tcp_memory"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"pressure_counters":' || { echo "FAIL: JSON output missing pressure_counters"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"drop_counters":' || { echo "FAIL: JSON output missing drop_counters"; exit 1; }
echo "PASS: Live audit returns valid schema"

# 4. Synthetic Healthy Fixture
TMP_DIR="$(mktemp -d /tmp/fm-jev-tcp-mem-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat << 'EOF' > "${TMP_DIR}/netstat.healthy"
TcpExt: SyncookiesSent SyncookiesRecv TCPMemoryPressures TCPAbortOnMemory PruneCalled RcvPruned OfoPruned TCPBacklogDrop TCPRcvQDrop TCPZeroWindowDrop TCPReqQFullDrop PFMemallocDrop
TcpExt: 0 0 0 0 10 5 0 0 0 0 0 0
IpExt: InNoRoutes InTruncatedPkts ReasmOverlaps
IpExt: 0 0 0
EOF

cat << 'EOF' > "${TMP_DIR}/tcp_mem.healthy"
100000 200000 300000
EOF

cat << 'EOF' > "${TMP_DIR}/sockstat.healthy"
sockets: used 120
TCP: inuse 10 orphan 0 tw 5 alloc 15 mem 500
UDP: inuse 2 mem 10
EOF

HEALTHY_OUT="$("${GUARD_SH}" --netstat-file "${TMP_DIR}/netstat.healthy" --tcp-mem-file "${TMP_DIR}/tcp_mem.healthy" --sockstat-file "${TMP_DIR}/sockstat.healthy" --json)"
echo "${HEALTHY_OUT}" | grep -q '"status": "HEALTHY"' || { echo "FAIL: Expected HEALTHY status"; exit 1; }
echo "PASS: Synthetic healthy fixture passes"

# 5. Synthetic Warning Fixture (elevated backlog drops)
cat << 'EOF' > "${TMP_DIR}/netstat.warn"
TcpExt: SyncookiesSent SyncookiesRecv TCPMemoryPressures TCPAbortOnMemory PruneCalled RcvPruned OfoPruned TCPBacklogDrop TCPRcvQDrop TCPZeroWindowDrop TCPReqQFullDrop PFMemallocDrop
TcpExt: 0 0 0 0 10 5 0 850 0 0 0 0
IpExt: InNoRoutes InTruncatedPkts ReasmOverlaps
IpExt: 0 0 0
EOF

set +e
"${GUARD_SH}" --netstat-file "${TMP_DIR}/netstat.warn" --tcp-mem-file "${TMP_DIR}/tcp_mem.healthy" --sockstat-file "${TMP_DIR}/sockstat.healthy" --json > "${TMP_DIR}/warn.out"
WARN_RC=$?
set -e

if [[ "${WARN_RC}" -ne 1 ]]; then
    echo "FAIL: Expected exit code 1 for WARNING, got ${WARN_RC}"
    exit 1
fi
grep -q '"status": "WARNING"' "${TMP_DIR}/warn.out" || { echo "FAIL: Expected WARNING status in JSON"; exit 1; }
echo "PASS: Synthetic warning fixture correctly triggers exit 1"

# 6. Synthetic Critical Fixture (TCPAbortOnMemory > 0)
cat << 'EOF' > "${TMP_DIR}/netstat.crit"
TcpExt: SyncookiesSent SyncookiesRecv TCPMemoryPressures TCPAbortOnMemory PruneCalled RcvPruned OfoPruned TCPBacklogDrop TCPRcvQDrop TCPZeroWindowDrop TCPReqQFullDrop PFMemallocDrop
TcpExt: 0 0 5 12 100 50 15 200 10 0 0 0
IpExt: InNoRoutes InTruncatedPkts ReasmOverlaps
IpExt: 0 0 0
EOF

set +e
"${GUARD_SH}" --netstat-file "${TMP_DIR}/netstat.crit" --tcp-mem-file "${TMP_DIR}/tcp_mem.healthy" --sockstat-file "${TMP_DIR}/sockstat.healthy" --json > "${TMP_DIR}/crit.out"
CRIT_RC=$?
set -e

if [[ "${CRIT_RC}" -ne 2 ]]; then
    echo "FAIL: Expected exit code 2 for CRITICAL, got ${CRIT_RC}"
    exit 1
fi
grep -q '"status": "CRITICAL"' "${TMP_DIR}/crit.out" || { echo "FAIL: Expected CRITICAL status in JSON"; exit 1; }
echo "PASS: Synthetic critical fixture correctly triggers exit 2"

echo "=== All 6/6 tests passed successfully! ==="
