#!/usr/bin/env bash
# tests/fm-jev-reorder-guard.test.sh - Regression tests for Pattern 151 (TCP Packet Reorder Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-reorder-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-reorder-guard.py"

echo "Running Pattern 151 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on host audit
json_out="$("$GUARD_SH" --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_reordering_threshold' in s
assert 'total_reorder_events' in s
assert 'sack_reorder' in s
assert 'ts_reorder' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-reorder-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    reorder_f = d / 'reorder'

    reorder_f.write_text('3\n')
    netstat_f.write_text('''TcpExt: TCPSACKReorder TCPTSReorder TCPRenoReorder TCPFastRetrans TCPFullUndo TCPDeliveredCE
TcpExt: 100 50 10 500 25 5
''')

    # Case 1: Nominal
    res = mod.audit_reorder(netstat_file=str(netstat_f), reorder_file=str(reorder_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_reordering_threshold'] == 3
    assert res['summary']['total_reorder_events'] == 160
    assert res['summary']['sack_reorder'] == 100

    # Case 2: Under-configured threshold (< 3) -> WARNING
    reorder_f.write_text('2\n')
    res2 = mod.audit_reorder(netstat_file=str(netstat_f), reorder_file=str(reorder_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('under-configured' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 151 regression tests passed!"
