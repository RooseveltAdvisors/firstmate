#!/usr/bin/env bash
# tests/fm-jev-zerowin-guard.test.sh - Regression tests for Pattern 110 (TCP Zero-Window Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-zerowin-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-zerowin-guard.py"

echo "Running Pattern 110 regression tests..."

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
assert 'tcp_autocorking' in s
assert 'zero_window_drops' in s
assert 'to_zero_window_advertised' in s
assert 'from_zero_window_received' in s
assert 'window_probes_sent' in s
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
mod = import_module('fm-jev-zerowin-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    autocorking_file = d / 'tcp_autocorking'
    netstat_file = d / 'netstat'

    autocorking_file.write_text('1\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPZeroWindowDrop TCPToZeroWindowAdv TCPFromZeroWindowAdv TCPWantZeroWindowAdv TCPWinProbe TCPAutoCorking
TcpExt: 0 0 100 200 210 50 1000
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_zerowin(
        autocorking_file=str(autocorking_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_autocorking'] is True
    assert res['summary']['zero_window_drops'] == 0
    assert res['summary']['to_zero_window_advertised'] == 100
    assert res['summary']['from_zero_window_received'] == 200
    assert res['summary']['window_probes_sent'] == 50

    # Case 2: Zero window drop warning
    drop_netstat = mock_netstat.replace(' 0 0 100 200 210 50 1000', ' 0 12 100 200 210 50 1000')
    netstat_file.write_text(drop_netstat)
    res2 = mod.audit_zerowin(
        autocorking_file=str(autocorking_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('packets dropped due to Zero Window' in iss for iss in res2['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 110 tests passed successfully!"
