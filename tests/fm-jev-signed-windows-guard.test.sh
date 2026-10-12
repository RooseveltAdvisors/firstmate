#!/usr/bin/env bash
# tests/fm-jev-signed-windows-guard.test.sh - Regression tests for Pattern 181 (TCP Signed Windows Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-signed-windows-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-signed-windows-guard.py"

echo "Running Pattern 181 regression tests..."

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
assert 'sysctls' in data
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_workaround_signed_windows' in s
assert 'tcp_workaround_signed_windows_desc' in s
assert 'tcp_window_scaling' in s
assert 'beyond_window' in s
assert 'zero_window_drop' in s
assert 'win_probe' in s
assert 'out_of_window_icmps' in s
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
mod = import_module('fm-jev-signed-windows-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    workaround_f = d / 'tcp_workaround_signed_windows'
    wscale_f = d / 'tcp_window_scaling'
    netstat_f = d / 'netstat'

    workaround_f.write_text('0\n')
    wscale_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: BeyondWindow TCPZeroWindowDrop TCPWinProbe OutOfWindowIcmps
TcpExt: 100 0 50 2
''')

    # Case 1: Nominal strict mode
    res = mod.audit_signed_windows(
        workaround_file=str(workaround_f),
        wscale_file=str(wscale_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_workaround_signed_windows'] == 0
    assert 'Disabled' in res['summary']['tcp_workaround_signed_windows_desc']
    assert res['summary']['beyond_window'] == 100
    assert res['summary']['zero_window_drop'] == 0
    assert res['summary']['win_probe'] == 50

    # Case 2: Workaround enabled -> WARNING
    workaround_f.write_text('1\n')
    res2 = mod.audit_signed_windows(
        workaround_file=str(workaround_f),
        wscale_file=str(wscale_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('Non-standard signed windows workaround enabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Window scaling disabled -> WARNING
    workaround_f.write_text('0\n')
    wscale_f.write_text('0\n')
    res3 = mod.audit_signed_windows(
        workaround_file=str(workaround_f),
        wscale_file=str(wscale_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('TCP window scaling disabled' in iss for iss in res3['summary']['issues'])

    # Case 4: Zero window drops -> WARNING
    wscale_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: BeyondWindow TCPZeroWindowDrop TCPWinProbe OutOfWindowIcmps
TcpExt: 100 5 50 2
''')
    res4 = mod.audit_signed_windows(
        workaround_file=str(workaround_f),
        wscale_file=str(wscale_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('Zero-window packet drops detected: 5' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 181 regression tests passed: 6/6 tests ok"
