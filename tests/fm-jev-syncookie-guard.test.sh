#!/usr/bin/env bash
# tests/fm-jev-syncookie-guard.test.sh - Regression tests for Pattern 118 (TCP SYN Cookie Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-syncookie-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-syncookie-guard.py"

echo "Running Pattern 118 regression tests..."

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
assert 'tcp_syncookies' in s
assert 'tcp_max_syn_backlog' in s
assert 'somaxconn' in s
assert 'syncookies_sent' in s
assert 'syncookies_recv' in s
assert 'syncookies_failed' in s
assert 'req_q_full_do_cookies' in s
assert 'req_q_full_drop' in s
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
mod = import_module('fm-jev-syncookie-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    syncookies_file = d / 'tcp_syncookies'
    backlog_file = d / 'tcp_max_syn_backlog'
    somaxconn_file = d / 'somaxconn'
    netstat_file = d / 'netstat'

    syncookies_file.write_text('1\n')
    backlog_file.write_text('4096\n')
    somaxconn_file.write_text('4096\n')

    mock_netstat = '''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed TCPReqQFullDoCookies TCPReqQFullDrop ListenOverflows ListenDrops
TcpExt: 10 10 0 5 0 0 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_syncookie(
        syncookies_file=str(syncookies_file),
        backlog_file=str(backlog_file),
        somaxconn_file=str(somaxconn_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_syncookies'] == 1
    assert res['summary']['tcp_max_syn_backlog'] == 4096
    assert res['summary']['syncookies_sent'] == 10
    assert res['summary']['req_q_full_drop'] == 0

    # Case 2: Disabled syncookies warning
    syncookies_file.write_text('0\n')
    res2 = mod.audit_syncookie(
        syncookies_file=str(syncookies_file),
        backlog_file=str(backlog_file),
        somaxconn_file=str(somaxconn_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_syncookies is disabled' in iss for iss in res2['summary']['issues'])
    syncookies_file.write_text('1\n')

    # Case 3: Low backlog warning
    backlog_file.write_text('256\n')
    res3 = mod.audit_syncookie(
        syncookies_file=str(syncookies_file),
        backlog_file=str(backlog_file),
        somaxconn_file=str(somaxconn_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('tcp_max_syn_backlog is low' in iss for iss in res3['summary']['issues'])
    backlog_file.write_text('4096\n')

    # Case 4: Request queue full drops warning
    drop_netstat = mock_netstat.replace(' 10 10 0 5 0 0 0', ' 10 10 0 5 25 0 0')
    netstat_file.write_text(drop_netstat)
    res4 = mod.audit_syncookie(
        syncookies_file=str(syncookies_file),
        backlog_file=str(backlog_file),
        somaxconn_file=str(somaxconn_file),
        netstat_file=str(netstat_file),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('TCP request queue full drops detected' in iss for iss in res4['summary']['issues'])

    # Case 5: High cookie validation failure rate
    fail_netstat = mock_netstat.replace(' 10 10 0 5 0 0 0', ' 200 50 50 5 0 0 0')
    netstat_file.write_text(fail_netstat)
    res5 = mod.audit_syncookie(
        syncookies_file=str(syncookies_file),
        backlog_file=str(backlog_file),
        somaxconn_file=str(somaxconn_file),
        netstat_file=str(netstat_file),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('Elevated SYN cookie validation failure rate' in iss for iss in res5['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 118 tests passed successfully!"
