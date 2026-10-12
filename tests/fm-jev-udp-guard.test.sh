#!/usr/bin/env bash
# tests/fm-jev-udp-guard.test.sh - Regression tests for Pattern 215 (UDP Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-udp-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-udp-guard.py"

echo "Running Pattern 215 (UDP Guard) regression tests..."

# 1. ShellCheck
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${BIN}"
    echo "ok - shellcheck clean"
else
    echo "ok - shellcheck skipped (not installed)"
fi

# 2. Python syntax
python3 -m py_compile "${PY}"
echo "ok - python syntax clean"

# 3. Help output
"${BIN}" --help >/dev/null
echo "ok - --help works"

# 4. JSON output schema validation
JSON_OUT="$("${BIN}" --json)"
python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
assert "timestamp" in data
assert "summary" in data
assert "status" in data["summary"]
assert "healthy" in data["summary"]
assert "total_sockets" in data["summary"]
assert "snmp_udp" in data
assert "sysctl" in data
assert "top_rx_sockets" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated queue overrun and MemErrors
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

mkdir -p "${MOCK_DIR}/sysctl"
echo "1525479 2033974 3050958" > "${MOCK_DIR}/sysctl/udp_mem"
echo "4096" > "${MOCK_DIR}/sysctl/udp_rmem_min"
echo "4096" > "${MOCK_DIR}/sysctl/udp_wmem_min"

cat << 'EOF' > "${MOCK_DIR}/mock_snmp"
Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors
Udp: 1000 10 50 1000 25 2 0 0 1
EOF

cat << 'EOF' > "${MOCK_DIR}/mock_udp"
   sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
    1: 00000000:0035 00000000:0000 07 00000000:00100000 00:00000000 00000000    0        0 12345 2 0000000000000000 10
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--proc-udp', '${MOCK_DIR}/mock_udp',
    '--proc-udp6', '/dev/null',
    '--proc-snmp', '${MOCK_DIR}/mock_snmp',
    '--sysctl-dir', '${MOCK_DIR}/sysctl',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'CRITICAL', f'Expected CRITICAL, got {data[\"summary\"][\"status\"]}'
assert data['summary']['total_sockets'] == 1
assert data['summary']['total_socket_drops'] == 10
assert data['snmp_udp']['mem_errors'] == 1
assert data['snmp_udp']['rcvbuf_errors'] == 25
assert len(data['top_drop_sockets']) == 1
assert data['top_drop_sockets'][0]['drops'] == 10
"
echo "ok - mock buffer drop detection and thresholds pass"

echo "All Pattern 215 tests passed!"
