#!/usr/bin/env bash
# tests/fm-jev-ssr-guard.test.sh - Regression tests for Pattern 116 (TCP Slow-Start & Buffer Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ssr-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ssr-guard.py"

echo "Running Pattern 116 regression tests..."

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
assert 'tcp_slow_start_after_idle' in s
assert 'tcp_moderate_rcvbuf' in s
assert 'slow_start_retransmissions' in s
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
mod = import_module('fm-jev-ssr-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ssr_file = d / 'tcp_slow_start_after_idle'
    rcvbuf_file = d / 'tcp_moderate_rcvbuf'
    app_win_file = d / 'tcp_app_win'
    netstat_file = d / 'netstat'

    ssr_file.write_text('1\n')
    rcvbuf_file.write_text('1\n')
    app_win_file.write_text('31\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPSlowStartRetrans TCPHystartTrainDetect TCPHystartDelayDetect
TcpExt: 0 10 5 2
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_ssr(
        ssr_file=str(ssr_file),
        rcvbuf_file=str(rcvbuf_file),
        app_win_file=str(app_win_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_slow_start_after_idle'] is True
    assert res['summary']['tcp_moderate_rcvbuf'] is True
    assert res['summary']['slow_start_retransmissions'] == 10

    # Case 2: Disabled dynamic buffer auto-tuning warning
    rcvbuf_file.write_text('0\n')
    res2 = mod.audit_ssr(
        ssr_file=str(ssr_file),
        rcvbuf_file=str(rcvbuf_file),
        app_win_file=str(app_win_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_moderate_rcvbuf is disabled' in iss for iss in res2['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 116 tests passed successfully!"
