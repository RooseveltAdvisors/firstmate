#!/usr/bin/env bash
# tests/fm-jev-wscale-guard.test.sh - Regression tests for Pattern 157 (TCP Window Scale Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-wscale-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-wscale-guard.py"

echo "Running Pattern 157 regression tests..."

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
assert 'tcp_window_scaling' in s
assert 'tcp_wmem' in s
assert 'tcp_rmem' in s
assert 'zero_win_drop' in s
assert 'win_probes' in s
assert 'beyond_win' in s
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
mod = import_module('fm-jev-wscale-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    wscale_f = d / 'tcp_window_scaling'
    wmem_f = d / 'tcp_wmem'
    rmem_f = d / 'tcp_rmem'
    adv_f = d / 'tcp_adv_win_scale'
    app_f = d / 'tcp_app_win'
    netstat_f = d / 'netstat'

    wscale_f.write_text('1\n')
    wmem_f.write_text('4096 16384 4194304\n')
    rmem_f.write_text('4096 131072 33554432\n')
    adv_f.write_text('1\n')
    app_f.write_text('31\n')
    netstat_f.write_text('''TcpExt: TCPZeroWindowDrop TCPWinProbe BeyondWindow
TcpExt: 0 100 50
''')

    # Case 1: Nominal
    res = mod.audit_wscale(
        wscale_file=str(wscale_f),
        wmem_file=str(wmem_f),
        rmem_file=str(rmem_f),
        adv_win_file=str(adv_f),
        app_win_file=str(app_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_window_scaling'] == 1
    assert res['summary']['zero_win_drop'] == 0
    assert res['summary']['win_probes'] == 100

    # Case 2: Disabled window scaling -> WARNING
    wscale_f.write_text('0\n')
    res2 = mod.audit_wscale(
        wscale_file=str(wscale_f),
        wmem_file=str(wmem_f),
        rmem_file=str(rmem_f),
        adv_win_file=str(adv_f),
        app_win_file=str(app_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_window_scaling is disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Zero-window drops detected -> WARNING
    wscale_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPZeroWindowDrop TCPWinProbe BeyondWindow
TcpExt: 15 100 50
''')
    res3 = mod.audit_wscale(
        wscale_file=str(wscale_f),
        wmem_file=str(wmem_f),
        rmem_file=str(rmem_f),
        adv_win_file=str(adv_f),
        app_win_file=str(app_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('zero-window packet drops' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 157 regression tests passed!"
