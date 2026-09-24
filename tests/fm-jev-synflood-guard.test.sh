#!/usr/bin/env bash
# tests/fm-jev-synflood-guard.test.sh - Regression tests for Pattern 233 (TCP SYN-Flood Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-synflood-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-synflood-guard.py"

echo "Running Pattern 233 regression tests..."

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
assert 'tcp_max_syn_backlog' in s
assert 'tcp_syncookies' in s
assert 'req_q_full_drop' in data['counters']
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
mod = import_module('fm-jev-synflood-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    backlog_f = d / 'tcp_max_syn_backlog'
    cookies_f = d / 'tcp_syncookies'
    retries_f = d / 'tcp_synack_retries'
    netstat_f = d / 'netstat'

    backlog_f.write_text('4096\n')
    cookies_f.write_text('1\n')
    retries_f.write_text('5\n')
    netstat_f.write_text('''TcpExt: TCPReqQFullDoCookies TCPReqQFullDrop TCPSynRetrans EmbryonicRsts SyncookiesSent SyncookiesRecv SyncookiesFailed
TcpExt: 0 0 100 10 0 0 0
''')

    # Case 1: Nominal
    res = mod.audit_synflood(
        max_syn_backlog_file=str(backlog_f),
        syncookies_file=str(cookies_f),
        synack_retries_file=str(retries_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_max_syn_backlog'] == 4096
    assert res['summary']['tcp_syncookies'] == 1
    assert res['counters']['req_q_full_drop'] == 0

    # Case 2: Syncookies disabled -> WARNING
    cookies_f.write_text('0\n')
    res2 = mod.audit_synflood(
        max_syn_backlog_file=str(backlog_f),
        syncookies_file=str(cookies_f),
        synack_retries_file=str(retries_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_syncookies is disabled' in iss for iss in res2['summary']['issues'])
    cookies_f.write_text('1\n')

    # Case 3: Request queue drops -> WARNING
    netstat_f.write_text('''TcpExt: TCPReqQFullDoCookies TCPReqQFullDrop TCPSynRetrans EmbryonicRsts SyncookiesSent SyncookiesRecv SyncookiesFailed
TcpExt: 50 15 100 10 50 45 0
''')
    res3 = mod.audit_synflood(
        max_syn_backlog_file=str(backlog_f),
        syncookies_file=str(cookies_f),
        synack_retries_file=str(retries_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('SYN request queue drops' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 233 regression tests passed!"
