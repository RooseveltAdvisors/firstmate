#!/usr/bin/env bash
# tests/fm-jev-netlink-guard.test.sh - Regression tests for Pattern 214 (Netlink Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-netlink-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-netlink-guard.py"

echo "Running Pattern 214 (Netlink Guard) regression tests..."

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
assert "total_drops" in data["summary"]
assert "protocols" in data
assert "sysctl" in data
assert "top_drop_sockets" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated drop overruns and memory exhaustion
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

mkdir -p "${MOCK_DIR}/sysctl"
echo "212992" > "${MOCK_DIR}/sysctl/rmem_default"
echo "212992" > "${MOCK_DIR}/sysctl/wmem_default"
echo "212992" > "${MOCK_DIR}/sysctl/rmem_max"
echo "212992" > "${MOCK_DIR}/sysctl/wmem_max"

# Create mock /proc/net/netlink with drops on NETLINK_ROUTE
cat << 'EOF' > "${MOCK_DIR}/mock_netlink"
sk               Eth Pid        Groups   Rmem     Wmem     Dump  Locks    Drops    Inode
0000000000000000 0   1234       00000111 1048576  0        0     2        25       99999
0000000000000000 15  5678       00000002 0        0        0     2        0        88888
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--proc-netlink', '${MOCK_DIR}/mock_netlink',
    '--sysctl-dir', '${MOCK_DIR}/sysctl',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'WARNING', f'Expected WARNING, got {data[\"summary\"][\"status\"]}'
assert data['summary']['total_drops'] == 25
assert data['summary']['sockets_with_drops'] == 1
assert data['summary']['total_sockets'] == 2
assert len(data['top_drop_sockets']) == 1
assert data['top_drop_sockets'][0]['protocol_name'] == 'NETLINK_ROUTE'
assert data['top_drop_sockets'][0]['drops'] == 25
"
echo "ok - mock buffer drop detection and thresholds pass"

echo "All Pattern 214 tests passed!"
