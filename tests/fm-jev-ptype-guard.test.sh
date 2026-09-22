#!/usr/bin/env bash
# tests/fm-jev-ptype-guard.test.sh - Regression tests for Pattern 220 (Packet Type Handler Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-ptype-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-ptype-guard.py"

echo "Running Pattern 220 (Packet Type Handler Guard) regression tests..."

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
assert "total_handlers" in data["summary"]
assert "wildcard_handlers" in data["summary"]
assert "handlers" in data
assert "by_protocol" in data
assert "by_device" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated wildcard packet tapping storm
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

cat << 'EOF' > "${MOCK_DIR}/mock_ptype"
Type Device      Function
ALL           tpacket_rcv
ALL           rogue_tap_1
ALL           rogue_tap_2
ALL           rogue_tap_3
ALL           rogue_tap_4
ALL           rogue_tap_5
0800          ip_rcv
86dd          ipv6_rcv
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--proc-ptype', '${MOCK_DIR}/mock_ptype',
    '--warn-wildcard', '5',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'WARNING', f'Expected WARNING, got {data[\"summary\"][\"status\"]}'
assert data['summary']['total_handlers'] == 8
assert data['summary']['wildcard_handlers'] == 6
assert any('Elevated wildcard packet taps' in i for i in data['summary']['issues'])
"
echo "ok - mock wildcard packet tap threshold alerts pass"

echo "All Pattern 220 tests passed!"
