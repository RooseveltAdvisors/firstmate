#!/usr/bin/env bash
# tests/fm-jev-ipv6-snmp-guard.test.sh - Regression tests for Pattern 221 (IPv6 SNMP6 Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-ipv6-snmp-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-ipv6-snmp-guard.py"

echo "Running Pattern 221 (IPv6 SNMP6 Guard) regression tests..."

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
assert "in_receives" in data["summary"]
assert "out_no_routes" in data["summary"]
assert "counters" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated UDP6 buffer drops and header errors
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

cat << 'EOF' > "${MOCK_DIR}/mock_snmp6"
Ip6InReceives 5000
Ip6InHdrErrors 15
Ip6InAddrErrors 0
Ip6InDiscards 20
Ip6InDelivers 4965
Ip6OutRequests 3000
Ip6OutNoRoutes 120
Udp6RcvbufErrors 60
Udp6MemErrors 2
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--proc-snmp6', '${MOCK_DIR}/mock_snmp6',
    '--no-route-check',
    '--warn-hdr-errors', '10',
    '--warn-udp-rcvbuf', '50',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'WARNING', f'Expected WARNING, got {data[\"summary\"][\"status\"]}'
assert data['summary']['in_hdr_errors'] == 15
assert data['summary']['udp6_rcvbuf_errors'] == 60
assert data['summary']['udp6_mem_errors'] == 2
assert any('IPv6 header/address errors elevated' in i for i in data['summary']['issues'])
assert any('UDP6 receive buffer overflow elevated' in i for i in data['summary']['issues'])
assert any('UDP6 kernel memory allocation errors detected' in i for i in data['summary']['issues'])
"
echo "ok - mock IPv6 error and buffer overflow threshold alerts pass"

echo "All Pattern 221 tests passed!"
