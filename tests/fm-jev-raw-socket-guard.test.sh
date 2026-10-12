#!/usr/bin/env bash
# tests/fm-jev-raw-socket-guard.test.sh - Regression tests for Pattern 222 (Raw Socket Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-raw-socket-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-raw-socket-guard.py"

echo "Running Pattern 222 (Raw Socket Guard) regression tests..."

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
assert "total_raw_sockets" in data["summary"]
assert "total_rx_queue_bytes" in data["summary"]
assert "sockets" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated raw socket queue memory leak and packet drops
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

cat << 'EOF' > "${MOCK_DIR}/mock_raw"
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
   0: 0100007F:0000 00000000:0000 07 00000000:00C00000 00:00000000 00000000  1000        0 123456789 2 0000000000000000 150
EOF

cat << 'EOF' > "${MOCK_DIR}/mock_raw6"
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--proc-raw', '${MOCK_DIR}/mock_raw',
    '--proc-raw6', '${MOCK_DIR}/mock_raw6',
    '--warn-rx-bytes', '10000000',
    '--warn-drops', '100',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'WARNING', f'Expected WARNING, got {data[\"summary\"][\"status\"]}'
assert data['summary']['total_raw_sockets'] == 1
assert data['summary']['ipv4_raw_sockets'] == 1
assert data['summary']['ipv6_raw_sockets'] == 0
assert data['summary']['total_rx_queue_bytes'] == 12582912 # 0x00C00000
assert data['summary']['total_drops'] == 150
assert any('Raw socket queued memory elevated' in i for i in data['summary']['issues'])
assert any('Raw socket packet drops elevated' in i for i in data['summary']['issues'])
"
echo "ok - mock raw socket memory leak and drop threshold alerts pass"

echo "All Pattern 222 tests passed!"
