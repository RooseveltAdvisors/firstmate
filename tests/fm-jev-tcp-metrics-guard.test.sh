#!/usr/bin/env bash
# tests/fm-jev-tcp-metrics-guard.test.sh - Regression tests for Pattern 216 (TCP Metrics Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${REPO_ROOT}/bin/fm-jev-tcp-metrics-guard.sh"
PY="${REPO_ROOT}/bin/fm-jev-tcp-metrics-guard.py"

echo "Running Pattern 216 (TCP Metrics Guard) regression tests..."

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
assert "total_entries" in data["summary"]
assert "tcp_no_metrics_save" in data["summary"]
assert "top_aged_entries" in data
' <<< "${JSON_OUT}"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly
"${BIN}" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Mock testing with simulated metrics bloat and thresholds
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

echo "0" > "${MOCK_DIR}/tcp_no_metrics_save"

cat << 'EOF' > "${MOCK_DIR}/mock_metrics"
10.0.0.1 age 3000000.000sec cwnd 4 ssthresh 10 rtt 650000us rttvar 15000us source 192.168.1.1
10.0.0.2 age 100.000sec cwnd 10 rtt 5000us rttvar 1000us source 192.168.1.1
EOF

python3 -c "
import json, subprocess, sys

cmd = [
    '${PY}',
    '--mock-file', '${MOCK_DIR}/mock_metrics',
    '--sysctl-file', '${MOCK_DIR}/tcp_no_metrics_save',
    '--warn-entries', '1',
    '--json'
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
data = json.loads(res.stdout)
assert data['summary']['status'] == 'WARNING', f'Expected WARNING, got {data[\"summary\"][\"status\"]}'
assert data['summary']['total_entries'] == 2
assert data['summary']['entries_over_30d'] == 1
assert data['summary']['low_cwnd_count'] == 1
assert data['summary']['high_rtt_count'] == 1
assert len(data['top_aged_entries']) == 2
assert data['top_aged_entries'][0]['dest_ip'] == '10.0.0.1'
"
echo "ok - mock metrics bloat detection and thresholds pass"

echo "All Pattern 216 tests passed!"
