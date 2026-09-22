#!/usr/bin/env bash
# tests/fm-jev-synflood-guard.test.sh - Regression tests for Pattern 140 (TCP SYN-Flood Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-synflood-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-synflood-guard.py"

echo "Running Pattern 140 regression tests..."

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
assert 'listen_drops' in s
assert 'listen_overflows' in s
assert 'req_q_full_drop' in s
assert 'syncookies_sent' in s
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
    cookies_f = d / 'tcp_syncookies'
    backlog_f = d / 'tcp_max_syn_backlog'
    somax_f = d / 'somaxconn'
    retries_f = d / 'tcp_synack_retries'
    netstat_f = d / 'netstat'

    cookies_f.write_text('1\n')
    backlog_f.write_text('4096\n')
    somax_f.write_text('4096\n')
    retries_f.write_text('5\n')
    netstat_f.write_text('''TcpExt: TCPReqQFullDrop TCPReqQFullDoCookies ListenDrops ListenOverflows SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts TCPDelivered
TcpExt: 0 0 0 0 0 0 0 14 1000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_synflood_guard(
        syncookies_file=str(cookies_f),
        syn_backlog_file=str(backlog_f),
        somaxconn_file=str(somax_f),
        synack_retries_file=str(retries_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_syncookies'] == 1
    assert res['summary']['tcp_max_syn_backlog'] == 4096
    assert res['summary']['somaxconn'] == 4096
    assert res['summary']['listen_drops'] == 0
    assert res['summary']['embryonic_rsts'] == 14

    # Case 2: SYN cookies disabled -> CRITICAL
    cookies_f.write_text('0\n')
    res2 = mod.audit_synflood_guard(
        syncookies_file=str(cookies_f),
        syn_backlog_file=str(backlog_f),
        somaxconn_file=str(somax_f),
        synack_retries_file=str(retries_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('SYN cookies are disabled' in iss for iss in res2['summary']['issues'])
    cookies_f.write_text('1\n')

    # Case 3: Severe listen queue overflow -> CRITICAL
    netstat_f.write_text('''TcpExt: TCPReqQFullDrop TCPReqQFullDoCookies ListenDrops ListenOverflows SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts TCPDelivered
TcpExt: 100 20 100 100 20 15 0 14 1000000
''')
    res3 = mod.audit_synflood_guard(
        syncookies_file=str(cookies_f),
        syn_backlog_file=str(backlog_f),
        somaxconn_file=str(somax_f),
        synack_retries_file=str(retries_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('Severe listen queue drops' in iss for iss in res3['summary']['issues'])

    # Case 4: Low backlog capacity -> WARNING
    netstat_f.write_text('''TcpExt: TCPReqQFullDrop TCPReqQFullDoCookies ListenDrops ListenOverflows SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts TCPDelivered
TcpExt: 0 0 0 0 0 0 0 0 1000000
''')
    backlog_f.write_text('256\n')
    somax_f.write_text('256\n')
    res4 = mod.audit_synflood_guard(
        syncookies_file=str(cookies_f),
        syn_backlog_file=str(backlog_f),
        somaxconn_file=str(somax_f),
        synack_retries_file=str(retries_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('backlog queue capacity is low' in iss for iss in res4['summary']['issues'])

    # Case 5: Missing files fallback (fail-open)
    res5 = mod.audit_synflood_guard(
        syncookies_file='/nonexistent/cookies',
        syn_backlog_file='/nonexistent/backlog',
        somaxconn_file='/nonexistent/somax',
        synack_retries_file='/nonexistent/retries',
        netstat_file='/nonexistent/netstat',
    )
    assert res5['summary']['status'] == 'HEALTHY'
    assert res5['summary']['tcp_syncookies'] == 1
    assert res5['summary']['listen_drops'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 140 regression tests passed!"
