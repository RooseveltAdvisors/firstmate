#!/usr/bin/env bash
# tests/fm-jev-rcvspace-guard.test.sh - Regression tests for Pattern 160 (TCP RCV Space Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rcvspace-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rcvspace-guard.py"

echo "Running Pattern 160 regression tests..."

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
assert 'memory_pressures' in s
assert 'backlog_drop' in s
assert 'rcv_collapsed' in s
assert 'rcv_q_drop' in s
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
mod = import_module('fm-jev-rcvspace-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    rcvbuf_f = d / 'tcp_moderate_rcvbuf'
    netstat_f = d / 'netstat'

    rcvbuf_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPMemoryPressures TCPBacklogDrop TCPRcvCollapsed TCPRcvQDrop
TcpExt: 0 0 41200 1300
''')

    # Case 1: Nominal
    res = mod.audit_rcvspace(
        moderate_rcvbuf_file=str(rcvbuf_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_moderate_rcvbuf'] == 1
    assert res['summary']['memory_pressures'] == 0
    assert res['summary']['backlog_drop'] == 0
    assert res['summary']['rcv_collapsed'] == 41200
    assert res['summary']['rcv_q_drop'] == 1300

    # Case 2: Disabled moderate_rcvbuf -> WARNING
    rcvbuf_f.write_text('0\n')
    res2 = mod.audit_rcvspace(
        moderate_rcvbuf_file=str(rcvbuf_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_moderate_rcvbuf is disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Memory pressures elevated -> WARNING
    rcvbuf_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPMemoryPressures TCPBacklogDrop TCPRcvCollapsed TCPRcvQDrop
TcpExt: 15 0 41200 1300
''')
    res3 = mod.audit_rcvspace(
        moderate_rcvbuf_file=str(rcvbuf_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('memory pressures' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 160 regression tests passed!"
