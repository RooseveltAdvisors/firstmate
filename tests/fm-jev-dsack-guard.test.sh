#!/usr/bin/env bash
# tests/fm-jev-dsack-guard.test.sh - Regression tests for Pattern 156 (TCP D-SACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-dsack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-dsack-guard.py"

echo "Running Pattern 156 regression tests..."

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
assert 'dsack_undo' in s
assert 'total_sent' in s
assert 'total_recv' in s
assert 'ignored_dubious' in s
assert 'dubious_ratio_pct' in s
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
mod = import_module('fm-jev-dsack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sysctl_f = d / 'tcp_dsack'
    netstat_f = d / 'netstat'

    sysctl_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPDSACKUndo TCPDSACKOldSent TCPDSACKOfoSent TCPDSACKRecv TCPDSACKOfoRecv TCPDSACKIgnoredDubious TCPDSACKIgnoredOld TCPDSACKIgnoredNoUndo
TcpExt: 1000 5000 100 8000 200 50 10 2000
''')

    # Case 1: Nominal (50 dubious / 8200 recv = 0.61%)
    res = mod.audit_dsack(sysctl_file=str(sysctl_f), netstat_file=str(netstat_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_dsack'] == 1
    assert res['summary']['total_sent'] == 5100
    assert res['summary']['total_recv'] == 8200
    assert res['summary']['dsack_undo'] == 1000
    assert res['summary']['ignored_dubious'] == 50
    assert res['summary']['dubious_ratio_pct'] == 0.61

    # Case 2: Disabled sysctl (0) -> WARNING
    sysctl_f.write_text('0\n')
    res2 = mod.audit_dsack(sysctl_file=str(sysctl_f), netstat_file=str(netstat_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_dsack is disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Elevated dubious ratio (> 20%) -> WARNING
    sysctl_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPDSACKUndo TCPDSACKOldSent TCPDSACKOfoSent TCPDSACKRecv TCPDSACKOfoRecv TCPDSACKIgnoredDubious TCPDSACKIgnoredOld TCPDSACKIgnoredNoUndo
TcpExt: 1000 5000 100 8000 200 2500 10 2000
''')
    res3 = mod.audit_dsack(sysctl_file=str(sysctl_f), netstat_file=str(netstat_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('Elevated dubious D-SACK ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 156 regression tests passed!"
