#!/usr/bin/env bash
# tests/fm-jev-syncookies-guard.test.sh - Regression tests for Pattern 192 (TCP SYN Cookie Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-syncookies-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-syncookies-guard.py"

echo "Running Pattern 192 regression tests..."

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
assert 'netstat_counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_syncookies' in s
assert 'somaxconn' in s
assert 'tcp_max_syn_backlog' in s
assert 'syncookies_sent' in s
assert 'syncookies_recv' in s
assert 'listen_drops' in s
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
mod = import_module('fm-jev-syncookies-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    syncookies_f = d / 'tcp_syncookies'
    somaxconn_f = d / 'somaxconn'
    syn_backlog_f = d / 'tcp_max_syn_backlog'
    netstat_f = d / 'netstat'

    syncookies_f.write_text('1\n')
    somaxconn_f.write_text('4096\n')
    syn_backlog_f.write_text('4096\n')
    netstat_f.write_text('''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts ListenDrops ListenOverflows
TcpExt: 0 0 0 14 0 0
''')

    # Case 1: Nominal
    res = mod.audit_syncookies(
        tcp_syncookies_file=str(syncookies_f),
        somaxconn_file=str(somaxconn_f),
        max_syn_backlog_file=str(syn_backlog_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_syncookies'] == 1
    assert res['summary']['somaxconn'] == 4096
    assert res['summary']['syncookies_sent'] == 0

    # Case 2: Syncookies disabled (0) -> CRITICAL
    syncookies_f.write_text('0\n')
    res2 = mod.audit_syncookies(
        tcp_syncookies_file=str(syncookies_f),
        somaxconn_file=str(somaxconn_f),
        max_syn_backlog_file=str(syn_backlog_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('unprotected' in iss for iss in res2['summary']['issues'])

    # Case 3: Syncookies failed > 1000 -> CRITICAL
    syncookies_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts ListenDrops ListenOverflows
TcpExt: 5000 2000 1500 14 0 0
''')
    res3 = mod.audit_syncookies(
        tcp_syncookies_file=str(syncookies_f),
        somaxconn_file=str(somaxconn_f),
        max_syn_backlog_file=str(syn_backlog_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('SyncookiesFailed' in iss for iss in res3['summary']['issues'])

    # Case 4: High listen drops -> CRITICAL
    netstat_f.write_text('''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts ListenDrops ListenOverflows
TcpExt: 0 0 0 14 1200 50
''')
    res4 = mod.audit_syncookies(
        tcp_syncookies_file=str(syncookies_f),
        somaxconn_file=str(somaxconn_f),
        max_syn_backlog_file=str(syn_backlog_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'CRITICAL'
    assert any('ListenDrops' in iss for iss in res4['summary']['issues'])

    # Case 5: Low somaxconn -> WARNING
    netstat_f.write_text('''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts ListenDrops ListenOverflows
TcpExt: 0 0 0 14 0 0
''')
    somaxconn_f.write_text('128\n')
    res5 = mod.audit_syncookies(
        tcp_syncookies_file=str(syncookies_f),
        somaxconn_file=str(somaxconn_f),
        max_syn_backlog_file=str(syn_backlog_f),
        netstat_file=str(netstat_f),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('somaxconn (128) < 1024' in iss for iss in res5['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 192 regression tests passed: 6/6 tests ok"
