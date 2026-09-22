#!/usr/bin/env bash
# tests/fm-jev-syn-guard.test.sh - Regression tests for Pattern 96 (TCP Syncookie & SYN Flood Backlog Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-syn-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-syn-guard.py"

echo "Running Pattern 96 regression tests..."

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
c = data['counters']
assert 'listen_overflows' in c
assert 'listen_drops' in c
assert 'tcp_backlog_drop' in c
assert 'syncookies_sent' in c
assert 'syncookies_recv' in c
assert 'syncookies_failed' in c
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-syn-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_path = d / 'netstat'
    syncookies_path = d / 'tcp_syncookies'
    syn_backlog_path = d / 'tcp_max_syn_backlog'
    somaxconn_path = d / 'somaxconn'

    syncookies_path.write_text('1\n')
    syn_backlog_path.write_text('4096\n')
    somaxconn_path.write_text('4096\n')

    # Nominal netstat
    netstat_nominal = '''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts ListenOverflows ListenDrops TCPBacklogDrop TCPReqQFullDoCookies TCPReqQFullDrop
TcpExt: 0 0 0 5 0 0 0 0 0
'''
    netstat_path.write_text(netstat_nominal)

    # Case 1: Healthy configuration and zero drops
    res = mod.audit_syn_backlog(
        netstat_file=str(netstat_path),
        syncookies_file=str(syncookies_path),
        syn_backlog_file=str(syn_backlog_path),
        somaxconn_file=str(somaxconn_path),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert len(res['summary']['issues']) == 0
    assert res['counters']['listen_overflows'] == 0

    # Case 2: Syncookies disabled triggers warning
    syncookies_path.write_text('0\n')
    res_no_cookies = mod.audit_syn_backlog(
        netstat_file=str(netstat_path),
        syncookies_file=str(syncookies_path),
        syn_backlog_file=str(syn_backlog_path),
        somaxconn_file=str(somaxconn_path),
    )
    assert res_no_cookies['summary']['status'] == 'WARNING'
    assert any('syncookies disabled' in iss for iss in res_no_cookies['summary']['issues'])

    # Case 3: Listen overflows and drops trigger warning
    syncookies_path.write_text('1\n')
    netstat_overflow = '''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts ListenOverflows ListenDrops TCPBacklogDrop TCPReqQFullDoCookies TCPReqQFullDrop
TcpExt: 10 8 2 5 15 12 4 10 3
'''
    netstat_path.write_text(netstat_overflow)
    res_overflow = mod.audit_syn_backlog(
        netstat_file=str(netstat_path),
        syncookies_file=str(syncookies_path),
        syn_backlog_file=str(syn_backlog_path),
        somaxconn_file=str(somaxconn_path),
    )
    assert res_overflow['summary']['status'] == 'WARNING'
    assert res_overflow['counters']['listen_overflows'] == 15
    assert res_overflow['counters']['listen_drops'] == 12
    assert res_overflow['counters']['tcp_backlog_drop'] == 4
    assert res_overflow['counters']['syncookies_failed'] == 2
    assert any('listen queue overflows' in iss for iss in res_overflow['summary']['issues'])
    assert any('TCP listen drops' in iss for iss in res_overflow['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 96 tests passed!"
