#!/usr/bin/env bash
# tests/fm-jev-xfrm-guard.test.sh - Verification suite for Pattern 224
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="${SCRIPT_DIR}/../bin/fm-jev-xfrm-guard.sh"
GUARD_PY="${SCRIPT_DIR}/../bin/fm-jev-xfrm-guard.py"

echo "=== Running fm-jev-xfrm-guard test suite ==="

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
echo "${LIVE_JSON}" | grep -q '"summary":' || { echo "FAIL: JSON output missing summary"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"inbound":' || { echo "FAIL: JSON output missing inbound"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"outbound":' || { echo "FAIL: JSON output missing outbound"; exit 1; }
echo "PASS: Live audit returns valid schema"

# 4. Synthetic Healthy Fixture
TMP_DIR="$(mktemp -d /tmp/fm-jev-xfrm-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat << 'EOF' > "${TMP_DIR}/xfrm_stat.healthy"
XfrmInError             	0
XfrmInBufferError       	0
XfrmInHdrError          	0
XfrmInNoStates          	0
XfrmInStateProtoError   	0
XfrmInStateModeError    	0
XfrmInStateSeqError     	0
XfrmInStateExpired      	0
XfrmInPolBlock          	0
XfrmOutError            	0
XfrmOutBundleGenError   	0
XfrmOutNoStates         	0
XfrmOutStateSeqError    	0
XfrmOutStateExpired     	0
XfrmOutPolBlock         	0
EOF

HEALTHY_OUT="$("${GUARD_SH}" --stat-file "${TMP_DIR}/xfrm_stat.healthy" --json)"
echo "${HEALTHY_OUT}" | grep -q '"status": "HEALTHY"' || { echo "FAIL: Expected HEALTHY status"; exit 1; }
echo "PASS: Synthetic healthy fixture passes"

# 5. Synthetic Warning Fixture (elevated transform/policy drops)
cat << 'EOF' > "${TMP_DIR}/xfrm_stat.warn"
XfrmInError             	45
XfrmInBufferError       	10
XfrmInHdrError          	0
XfrmInNoStates          	25
XfrmInStateProtoError   	0
XfrmInStateModeError    	0
XfrmInStateSeqError     	5
XfrmInStateExpired      	15
XfrmInPolBlock          	60
XfrmOutError            	20
XfrmOutBundleGenError   	0
XfrmOutNoStates         	10
XfrmOutStateSeqError    	5
XfrmOutStateExpired     	10
XfrmOutPolBlock         	20
EOF

set +e
"${GUARD_SH}" --stat-file "${TMP_DIR}/xfrm_stat.warn" --json > "${TMP_DIR}/warn.out"
WARN_RC=$?
set -e

if [[ "${WARN_RC}" -ne 1 ]]; then
    echo "FAIL: Expected exit code 1 for WARNING, got ${WARN_RC}"
    exit 1
fi
grep -q '"status": "WARNING"' "${TMP_DIR}/warn.out" || { echo "FAIL: Expected WARNING status in JSON"; exit 1; }
echo "PASS: Synthetic warning fixture correctly triggers exit 1"

# 6. Synthetic Critical Fixture (replay sequence errors > threshold)
cat << 'EOF' > "${TMP_DIR}/xfrm_stat.crit"
XfrmInError             	10
XfrmInBufferError       	0
XfrmInHdrError          	0
XfrmInNoStates          	0
XfrmInStateProtoError   	0
XfrmInStateModeError    	0
XfrmInStateSeqError     	85
XfrmInStateExpired      	0
XfrmInPolBlock          	0
XfrmOutError            	0
XfrmOutBundleGenError   	0
XfrmOutNoStates         	0
XfrmOutStateSeqError    	10
XfrmOutStateExpired     	0
XfrmOutPolBlock         	0
EOF

set +e
"${GUARD_SH}" --stat-file "${TMP_DIR}/xfrm_stat.crit" --json > "${TMP_DIR}/crit.out"
CRIT_RC=$?
set -e

if [[ "${CRIT_RC}" -ne 2 ]]; then
    echo "FAIL: Expected exit code 2 for CRITICAL, got ${CRIT_RC}"
    exit 1
fi
grep -q '"status": "CRITICAL"' "${TMP_DIR}/crit.out" || { echo "FAIL: Expected CRITICAL status in JSON"; exit 1; }
echo "PASS: Synthetic critical fixture correctly triggers exit 2"

echo "=== All 6/6 tests passed successfully! ==="
