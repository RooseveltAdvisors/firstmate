#!/usr/bin/env bash
# tests/fm-jev-qdisc-guard.test.sh - Regression tests for Pattern 219 (Qdisc Backlog Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-qdisc-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-qdisc-guard.py"

echo "Running Pattern 219 (Qdisc Backlog Guard) regression tests..."

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
assert "total_qdiscs" in data["summary"]
assert "default_qdisc" in data["summary"]
assert "qdiscs" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated backlog bufferbloat queue
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

cat << 'EOF' > "${MOCK_DIR}/mock_tc.txt"
qdisc fq_codel 0: dev enp7s0 root refcnt 2 limit 10240p flows 1024
 Sent 1000000 bytes 10000 pkt (dropped 0, overlimits 0 requeues 0) 
 backlog 6000000b 2500p requeues 0
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--mock-file', '${MOCK_DIR}/mock_tc.txt',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'CRITICAL', f'Expected CRITICAL, got {data[\"summary\"][\"status\"]}'
assert data['summary']['total_qdiscs'] == 1
assert data['summary']['total_backlog_bytes'] == 6000000
assert data['summary']['total_backlog_pkts'] == 2500
assert any('Traffic control queue backlog critical' in i for i in data['summary']['issues'])
"
echo "ok - mock bufferbloat backlog and threshold alerts pass"

echo "All Pattern 219 tests passed!"
