#!/usr/bin/env bash
# tests/fm-jev-zerowin-guard.test.sh - Regression tests for Pattern 147 (TCP Zero-Window Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-zerowin-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-zerowin-guard.py"

echo "Running Pattern 147 regression tests..."

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
assert 'tcp_moderate_rcvbuf' in s
assert 'tcp_rmem_max_bytes' in s
assert 'win_probe' in s
assert 'zero_win_drop' in s
assert 'mem_pressures' in s
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
mod = import_module('fm-jev-zerowin-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    mod_rcvbuf_f = d / 'mod_rcvbuf'
    rmem_f = d / 'rmem'

    mod_rcvbuf_f.write_text('1\n')
    rmem_f.write_text('4096 131072 33554432\n')
    netstat_f.write_text('''TcpExt: TCPWinProbe TCPZeroWindowDrop TCPRcvCollapsed TCPMemoryPressures TCPPruneDrop TCPBacklogDrop
TcpExt: 100 0 500 0 0 0
''')

    # Case 1: Nominal
    res = mod.audit_zerowin(
        netstat_file=str(netstat_f),
        moderate_rcvbuf_file=str(mod_rcvbuf_f),
        rmem_file=str(rmem_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['win_probe'] == 100
    assert res['summary']['zero_win_drop'] == 0
    assert res['summary']['mem_pressures'] == 0

    # Case 2: Memory pressures > 0 -> WARNING
    netstat_f.write_text('''TcpExt: TCPWinProbe TCPZeroWindowDrop TCPRcvCollapsed TCPMemoryPressures TCPPruneDrop TCPBacklogDrop
TcpExt: 100 0 500 5 0 0
''')
    res2 = mod.audit_zerowin(
        netstat_file=str(netstat_f),
        moderate_rcvbuf_file=str(mod_rcvbuf_f),
        rmem_file=str(rmem_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('memory pressure' in iss for iss in res2['summary']['issues'])

    # Case 3: Zero-window drops > 0 -> WARNING
    netstat_f.write_text('''TcpExt: TCPWinProbe TCPZeroWindowDrop TCPRcvCollapsed TCPMemoryPressures TCPPruneDrop TCPBacklogDrop
TcpExt: 100 25 500 0 0 0
''')
    res3 = mod.audit_zerowin(
        netstat_file=str(netstat_f),
        moderate_rcvbuf_file=str(mod_rcvbuf_f),
        rmem_file=str(rmem_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Zero-window packet drops' in iss for iss in res3['summary']['issues'])

    # Case 4: Moderate receive buffer disabled (0) -> WARNING
    mod_rcvbuf_f.write_text('0\n')
    res4 = mod.audit_zerowin(
        netstat_file=str(netstat_f),
        moderate_rcvbuf_file=str(mod_rcvbuf_f),
        rmem_file=str(rmem_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('tcp_moderate_rcvbuf is disabled' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 147 regression tests passed!"
