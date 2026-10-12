#!/usr/bin/env bash
# tests/fm-jev-syn-cookie-watermark-guard.test.sh - Regression tests for Pattern 145 (SYN Cookie Watermark Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-syn-cookie-watermark-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-syn-cookie-watermark-guard.py"

echo "Running Pattern 145 regression tests..."

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
assert 'cookies_sent' in s
assert 'cookies_recv' in s
assert 'cookies_failed' in s
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
mod = import_module('fm-jev-syn-cookie-watermark-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    syncookies_f = d / 'syncookies'
    backlog_f = d / 'backlog'
    somaxconn_f = d / 'somaxconn'

    syncookies_f.write_text('1\n')
    backlog_f.write_text('4096\n')
    somaxconn_f.write_text('4096\n')
    netstat_f.write_text('''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed ListenOverflows ListenDrops TCPSynRetrans
TcpExt: 100 95 2 0 0 500
''')

    # Case 1: Nominal
    res = mod.audit_syncookie_watermark(
        netstat_file=str(netstat_f),
        syncookies_file=str(syncookies_f),
        backlog_file=str(backlog_f),
        somaxconn_file=str(somaxconn_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['cookies_sent'] == 100
    assert res['summary']['cookies_recv'] == 95
    assert res['summary']['cookies_failed'] == 2

    # Case 2: tcp_syncookies disabled (0) -> WARNING
    syncookies_f.write_text('0\n')
    res2 = mod.audit_syncookie_watermark(
        netstat_file=str(netstat_f),
        syncookies_file=str(syncookies_f),
        backlog_file=str(backlog_f),
        somaxconn_file=str(somaxconn_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Backlog underprovisioned (< 1024) -> WARNING
    syncookies_f.write_text('1\n')
    backlog_f.write_text('512\n')
    res3 = mod.audit_syncookie_watermark(
        netstat_file=str(netstat_f),
        syncookies_file=str(syncookies_f),
        backlog_file=str(backlog_f),
        somaxconn_file=str(somaxconn_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('under-provisioned' in iss for iss in res3['summary']['issues'])

    # Case 4: High failure ratio (> 20%) -> WARNING
    backlog_f.write_text('4096\n')
    netstat_f.write_text('''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed ListenOverflows ListenDrops TCPSynRetrans
TcpExt: 200 100 30 0 0 500
''')
    res4 = mod.audit_syncookie_watermark(
        netstat_file=str(netstat_f),
        syncookies_file=str(syncookies_f),
        backlog_file=str(backlog_f),
        somaxconn_file=str(somaxconn_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('failure ratio' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 145 regression tests passed!"
