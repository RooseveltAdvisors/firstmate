#!/usr/bin/env bash
# tests/fm-jev-reorder-guard.test.sh - Regression tests for Pattern 112 (TCP DSACK & Reordering Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-reorder-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-reorder-guard.py"

echo "Running Pattern 112 regression tests..."

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
assert 'tcp_dsack' in s
assert 'tcp_reordering_threshold' in s
assert 'total_reorder_events' in s
assert 'total_cwnd_undos' in s
assert 'dsack_undo_events' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-reorder-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    dsack_file = d / 'tcp_dsack'
    reordering_file = d / 'tcp_reordering'
    netstat_file = d / 'netstat'

    dsack_file.write_text('1\n')
    reordering_file.write_text('3\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPSACKReorder TCPRenoReorder TCPTSReorder TCPDSACKOldSent TCPDSACKOfoSent TCPDSACKRecv TCPDSACKUndo TCPFullUndo TCPPartialUndo TCPLossUndo
TcpExt: 0 500 0 10 100 5 120 25 5 2 20
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_reorder(
        dsack_file=str(dsack_file),
        reordering_file=str(reordering_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_dsack'] is True
    assert res['summary']['tcp_reordering_threshold'] == 3
    assert res['summary']['total_reorder_events'] == 510
    assert res['summary']['total_cwnd_undos'] == 52
    assert res['summary']['dsack_undo_events'] == 25

    # Case 2: DSACK disabled warning
    dsack_file.write_text('0\n')
    res2 = mod.audit_reorder(
        dsack_file=str(dsack_file),
        reordering_file=str(reordering_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_dsack is disabled' in iss for iss in res2['summary']['issues'])
    dsack_file.write_text('1\n')

    # Case 3: Low reordering threshold warning
    reordering_file.write_text('2\n')
    res3 = mod.audit_reorder(
        dsack_file=str(dsack_file),
        reordering_file=str(reordering_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Low tcp_reordering threshold' in iss for iss in res3['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 112 tests passed successfully!"
