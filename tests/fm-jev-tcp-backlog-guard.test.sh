#!/usr/bin/env bash
# tests/fm-jev-tcp-backlog-guard.test.sh - Regression tests for Pattern 78 (TCP Backlog Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tcp-backlog-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tcp-backlog-guard.py"

echo "Running Pattern 78 regression tests..."

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
assert 'sysctl' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'total_listen_sockets' in s
assert 'saturated_sockets_count' in s
assert 'max_socket_saturation_pct' in s
assert 'listen_overflows' in s
assert 'listen_drops' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs files and mock sockets
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-tcp-backlog-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_netstat = os.path.join(tmp_dir, 'netstat')
    mock_somaxconn = os.path.join(tmp_dir, 'somaxconn')
    mock_syn = os.path.join(tmp_dir, 'tcp_max_syn_backlog')
    mock_cookies = os.path.join(tmp_dir, 'tcp_syncookies')

    with open(mock_somaxconn, 'w') as f:
        f.write('4096\n')
    with open(mock_syn, 'w') as f:
        f.write('4096\n')
    with open(mock_cookies, 'w') as f:
        f.write('1\n')

    with open(mock_netstat, 'w') as f:
        f.write('TcpExt: SyncookiesSent SyncookiesRecv ListenOverflows ListenDrops TCPBacklogDrop TCPReqQFullDoCookies TCPReqQFullDrop TCPTimeWaitOverflow\n')
        f.write('TcpExt: 0 0 0 0 0 0 0 0\n')

    # Audit under normal conditions
    mock_socks = [
        {'local_address': '127.0.0.1:8000', 'recv_q': 0, 'send_q': 128, 'saturation_pct': 0.0},
        {'local_address': '0.0.0.0:443', 'recv_q': 5, 'send_q': 512, 'saturation_pct': 0.98},
    ]
    res = mod.audit_tcp_backlog(
        netstat_path=mock_netstat,
        somaxconn_path=mock_somaxconn,
        syn_backlog_path=mock_syn,
        syncookies_path=mock_cookies,
        mock_sockets=mock_socks,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['total_listen_sockets'] == 2
    assert s['saturated_sockets_count'] == 0
    assert s['listen_overflows'] == 0

    # Test WARNING on elevated socket saturation (e.g. 75%)
    mock_socks_warn = [
        {'local_address': '127.0.0.1:8000', 'recv_q': 96, 'send_q': 128, 'saturation_pct': 75.0},
    ]
    res_warn = mod.audit_tcp_backlog(
        netstat_path=mock_netstat,
        somaxconn_path=mock_somaxconn,
        syn_backlog_path=mock_syn,
        mock_sockets=mock_socks_warn,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('Elevated listen socket' in iss for iss in res_warn['summary']['issues'])

    # Test CRITICAL on near-full queue (e.g. 95%)
    mock_socks_crit = [
        {'local_address': '127.0.0.1:8000', 'recv_q': 122, 'send_q': 128, 'saturation_pct': 95.31},
    ]
    res_crit = mod.audit_tcp_backlog(
        netstat_path=mock_netstat,
        somaxconn_path=mock_somaxconn,
        syn_backlog_path=mock_syn,
        mock_sockets=mock_socks_crit,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('Critical listen socket' in iss for iss in res_crit['summary']['issues'])

    # Test WARNING on low somaxconn sysctl
    with open(mock_somaxconn, 'w') as f:
        f.write('64\n') # low < 128
    res_sysctl = mod.audit_tcp_backlog(
        netstat_path=mock_netstat,
        somaxconn_path=mock_somaxconn,
        syn_backlog_path=mock_syn,
        mock_sockets=mock_socks,
    )
    assert res_sysctl['summary']['status'] == 'WARNING'
    assert any('somaxconn' in iss for iss in res_sysctl['summary']['issues'])

    # Test WARNING on ListenOverflows > 0
    with open(mock_somaxconn, 'w') as f:
        f.write('4096\n')
    with open(mock_netstat, 'w') as f:
        f.write('TcpExt: SyncookiesSent SyncookiesRecv ListenOverflows ListenDrops TCPBacklogDrop TCPReqQFullDoCookies TCPReqQFullDrop TCPTimeWaitOverflow\n')
        f.write('TcpExt: 0 0 12 0 0 0 0 0\n')
    res_overflow = mod.audit_tcp_backlog(
        netstat_path=mock_netstat,
        somaxconn_path=mock_somaxconn,
        syn_backlog_path=mock_syn,
        mock_sockets=mock_socks,
    )
    assert res_overflow['summary']['status'] == 'WARNING'
    assert res_overflow['summary']['listen_overflows'] == 12
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 78 tests passed!"
