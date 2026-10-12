#!/usr/bin/env bash
# tests/fm-jev-ktls-guard.test.sh - Verification suite for Pattern 225
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="${SCRIPT_DIR}/../bin/fm-jev-ktls-guard.sh"
GUARD_PY="${SCRIPT_DIR}/../bin/fm-jev-ktls-guard.py"

echo "=== Running fm-jev-ktls-guard test suite ==="

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
echo "${LIVE_JSON}" | grep -q '"ulp_available":' || { echo "FAIL: JSON output missing ulp_available"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"active_sessions":' || { echo "FAIL: JSON output missing active_sessions"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"traffic":' || { echo "FAIL: JSON output missing traffic"; exit 1; }
echo "${LIVE_JSON}" | grep -q '"integrity":' || { echo "FAIL: JSON output missing integrity"; exit 1; }
echo "PASS: Live audit returns valid schema"

# 4. Synthetic Healthy Fixture
TMP_DIR="$(mktemp -d /tmp/fm-jev-ktls-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat << 'EOF' > "${TMP_DIR}/tls_stat.healthy"
TlsCurrTxSw                     	0
TlsCurrRxSw                     	0
TlsCurrTxDevice                 	0
TlsCurrRxDevice                 	0
TlsTxSw                         	100
TlsRxSw                         	100
TlsTxDevice                     	0
TlsRxDevice                     	0
TlsDecryptError                 	0
TlsRxDeviceResync               	0
TlsDecryptRetry                 	0
TlsRxNoPadViolation             	0
TlsRxRekeyOk                    	0
TlsRxRekeyError                 	0
TlsTxRekeyOk                    	0
TlsTxRekeyError                 	0
TlsRxRekeyReceived              	0
EOF

HEALTHY_OUT="$("${GUARD_SH}" --stat-path "${TMP_DIR}/tls_stat.healthy" --json)"
echo "${HEALTHY_OUT}" | grep -q '"status": "HEALTHY"' || { echo "FAIL: Expected HEALTHY status"; exit 1; }
echo "${HEALTHY_OUT}" | grep -q '"total_records": 200' || { echo "FAIL: Expected 200 total records"; exit 1; }
echo "PASS: Synthetic healthy fixture passes"

# 5. Synthetic Warning Fixture (elevated decryption errors)
cat << 'EOF' > "${TMP_DIR}/tls_stat.warn"
TlsCurrTxSw                     	2
TlsCurrRxSw                     	2
TlsCurrTxDevice                 	0
TlsCurrRxDevice                 	0
TlsTxSw                         	500
TlsRxSw                         	500
TlsTxDevice                     	0
TlsRxDevice                     	0
TlsDecryptError                 	15
TlsRxDeviceResync               	0
TlsDecryptRetry                 	2
TlsRxNoPadViolation             	0
TlsRxRekeyOk                    	0
TlsRxRekeyError                 	0
TlsTxRekeyOk                    	0
TlsTxRekeyError                 	0
TlsRxRekeyReceived              	0
EOF

set +e
WARN_OUT="$("${GUARD_SH}" --stat-path "${TMP_DIR}/tls_stat.warn" --json)"
EXIT_CODE=$?
set -e
test ${EXIT_CODE} -ne 0 || { echo "FAIL: Expected non-zero exit code on warning/error"; exit 1; }
echo "${WARN_OUT}" | grep -q '"status": "WARNING"' || { echo "FAIL: Expected WARNING status"; exit 1; }
echo "${WARN_OUT}" | grep -q 'Elevated kTLS decryption errors' || { echo "FAIL: Missing warning issue text"; exit 1; }
echo "PASS: Synthetic warning fixture passes"

# 6. Synthetic Critical Fixture (high rekey failures)
cat << 'EOF' > "${TMP_DIR}/tls_stat.crit"
TlsCurrTxSw                     	10
TlsCurrRxSw                     	10
TlsCurrTxDevice                 	0
TlsCurrRxDevice                 	0
TlsTxSw                         	2000
TlsRxSw                         	2000
TlsTxDevice                     	0
TlsRxDevice                     	0
TlsDecryptError                 	0
TlsRxDeviceResync               	0
TlsDecryptRetry                 	0
TlsRxNoPadViolation             	0
TlsRxRekeyOk                    	5
TlsRxRekeyError                 	120
TlsTxRekeyOk                    	5
TlsTxRekeyError                 	10
TlsRxRekeyReceived              	150
EOF

set +e
CRIT_OUT="$("${GUARD_SH}" --stat-path "${TMP_DIR}/tls_stat.crit" --json)"
EXIT_CODE=$?
set -e
test ${EXIT_CODE} -ne 0 || { echo "FAIL: Expected non-zero exit code on critical"; exit 1; }
echo "${CRIT_OUT}" | grep -q '"status": "CRITICAL"' || { echo "FAIL: Expected CRITICAL status"; exit 1; }
echo "${CRIT_OUT}" | grep -q 'High kTLS rekeying failures' || { echo "FAIL: Missing critical issue text"; exit 1; }
echo "PASS: Synthetic critical fixture passes"

echo "=== All 6 tests in fm-jev-ktls-guard passed successfully! ==="
