#!/usr/bin/env bash
# tests/fm-jev-packet-ring-guard.test.sh - Regression tests for Pattern 218 (Packet Ring Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-packet-ring-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-packet-ring-guard.py"

echo "Running Pattern 218 (Packet Ring Guard) regression tests..."

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
assert "total_packet_sockets" in data["summary"]
assert "ethertypes" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated packet queue accumulation
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

cat << 'EOF' > "${MOCK_DIR}/mock_packet"
sk               RefCnt Type Proto  Iface R Rmem   User   Inode
0000000000000000 3      2    0003   0     0 12000000 0   12345
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--proc-packet', '${MOCK_DIR}/mock_packet',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'WARNING', f'Expected WARNING, got {data[\"summary\"][\"status\"]}'
assert data['summary']['total_packet_sockets'] == 1
assert data['summary']['promiscuous_all_sockets'] == 1
assert data['summary']['ring_buffer_sockets'] == 0
assert data['summary']['total_rmem_bytes'] == 12000000
assert any('Raw packet socket memory elevated' in i for i in data['summary']['issues'])
"
echo "ok - mock buffer accumulation and threshold alerts pass"

echo "All Pattern 218 tests passed!"
