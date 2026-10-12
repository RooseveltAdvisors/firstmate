#!/usr/bin/env bash
# tests/fm-jev-zero-window-adv-guard.test.sh - Regression tests for Pattern 162 (TCP Zero-Window Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-zero-window-adv-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-zero-window-adv-guard.py"

echo "Running Pattern 162 regression tests..."

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
assert 'to_zero_window' in s
assert 'from_zero_window' in s
assert 'want_zero_window' in s
assert 'zero_window_drop' in s
assert 'rcv_q_drop' in s
assert 'net_zero_active' in s
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
mod = import_module('fm-jev-zero-window-adv-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    app_win_f = d / 'tcp_app_win'
    adv_scale_f = d / 'tcp_adv_win_scale'

    app_win_f.write_text('31\n')
    adv_scale_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPToZeroWindowAdv TCPFromZeroWindowAdv TCPWantZeroWindowAdv TCPZeroWindowDrop TCPRcvQDrop
TcpExt: 50000 50000 50000 0 100
''')

    # Case 1: Nominal
    res = mod.audit_zero_window(
        netstat_file=str(netstat_f),
        app_win_file=str(app_win_f),
        adv_win_scale_file=str(adv_scale_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['to_zero_window'] == 50000
    assert res['summary']['from_zero_window'] == 50000
    assert res['summary']['net_zero_active'] == 0

    # Case 2: High zero-window drops -> WARNING
    netstat_f.write_text('''TcpExt: TCPToZeroWindowAdv TCPFromZeroWindowAdv TCPWantZeroWindowAdv TCPZeroWindowDrop TCPRcvQDrop
TcpExt: 50000 50000 50000 60 100
''')
    res2 = mod.audit_zero_window(
        netstat_file=str(netstat_f),
        app_win_file=str(app_win_f),
        adv_win_scale_file=str(adv_scale_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('zero-window packet drops' in iss for iss in res2['summary']['issues'])

    # Case 3: High net active zero window sockets -> WARNING
    netstat_f.write_text('''TcpExt: TCPToZeroWindowAdv TCPFromZeroWindowAdv TCPWantZeroWindowAdv TCPZeroWindowDrop TCPRcvQDrop
TcpExt: 50200 50000 50200 0 100
''')
    res3 = mod.audit_zero_window(
        netstat_file=str(netstat_f),
        app_win_file=str(app_win_f),
        adv_win_scale_file=str(adv_scale_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('active zero-window advertised sockets' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 162 regression tests passed!"
