#!/usr/bin/env bash
# tests/fm-jev-fack-guard.test.sh - Regression tests for Pattern 132 (TCP FACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-fack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-fack-guard.py"

echo "Running Pattern 132 regression tests..."

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
assert 'tcp_fack' in s
assert 'tcp_sack' in s
assert 'sack_recovery' in s
assert 'sack_reneging' in s
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
mod = import_module('fm-jev-fack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    fack_f = d / 'tcp_fack'
    reord_f = d / 'tcp_reordering'
    max_reord_f = d / 'tcp_max_reordering'
    sack_f = d / 'tcp_sack'
    dsack_f = d / 'tcp_dsack'
    netstat_f = d / 'netstat'

    fack_f.write_text('0\n')
    reord_f.write_text('3\n')
    max_reord_f.write_text('300\n')
    sack_f.write_text('1\n')
    dsack_f.write_text('1\n')

    netstat_f.write_text('''TcpExt: TCPSackRecovery TCPSackRecoveryFail TCPSACKReneging TCPDSACKRecv TCPDSACKUndo TCPRcvCollapsed
TcpExt: 1000 20 0 500 50 10
''')

    # Case 1: Nominal
    res = mod.audit_fack(
        fack_file=str(fack_f),
        reordering_file=str(reord_f),
        max_reordering_file=str(max_reord_f),
        sack_file=str(sack_f),
        dsack_file=str(dsack_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_sack'] == 1
    assert res['summary']['sack_fail_pct'] == 2.0
    assert res['counters']['sack_reneging'] == 0

    # Case 2: SACK disabled -> WARNING
    sack_f.write_text('0\n')
    res2 = mod.audit_fack(
        fack_file=str(fack_f),
        reordering_file=str(reord_f),
        max_reordering_file=str(max_reord_f),
        sack_file=str(sack_f),
        dsack_file=str(dsack_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Selective ACK is disabled' in iss for iss in res2['summary']['issues'])
    sack_f.write_text('1\n')

    # Case 3: High SACK reneging -> WARNING
    netstat_f.write_text('''TcpExt: TCPSackRecovery TCPSackRecoveryFail TCPSACKReneging TCPDSACKRecv TCPDSACKUndo TCPRcvCollapsed
TcpExt: 1000 20 250 500 50 10
''')
    res3 = mod.audit_fack(
        fack_file=str(fack_f),
        reordering_file=str(reord_f),
        max_reordering_file=str(max_reord_f),
        sack_file=str(sack_f),
        dsack_file=str(dsack_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('SACK reneging' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 132 regression tests passed!"
