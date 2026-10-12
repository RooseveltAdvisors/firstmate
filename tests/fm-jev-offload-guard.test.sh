#!/usr/bin/env bash
# tests/fm-jev-offload-guard.test.sh - Regression tests for Pattern 217 (GRO Offload Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-offload-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-offload-guard.py"

echo "Running Pattern 217 (Offload Guard) regression tests..."

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
assert "interfaces" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated LRO enabled
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

cat << 'EOF' > "${MOCK_DIR}/eth0_ethtool.txt"
Features for eth0:
generic-receive-offload: on
generic-segmentation-offload: on
large-receive-offload: on
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--mock-dir', '${MOCK_DIR}',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'WARNING', f'Expected WARNING, got {data[\"summary\"][\"status\"]}'
assert 'eth0' in data['interfaces']
assert data['interfaces']['eth0']['features']['large-receive-offload']['enabled'] is True
assert any('Large Receive Offload' in i for i in data['summary']['issues'])
"
echo "ok - mock LRO risk detection passes"

echo "All Pattern 217 tests passed!"
