#!/usr/bin/env bash
# tests/fm-jev-bbr-guard.test.sh - Regression tests for Pattern 106 (TCP Congestion Control & Pacing Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-bbr-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-bbr-guard.py"

echo "Running Pattern 106 regression tests..."

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
assert 'current_congestion_control' in s
assert 'available_algorithms' in s
assert 'pacing_ss_ratio' in s
assert 'pacing_ca_ratio' in s
assert 'spurious_rtos' in s
assert 'receive_collapsed' in s
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
mod = import_module('fm-jev-bbr-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    cc_file = d / 'tcp_congestion_control'
    avail_file = d / 'tcp_available_congestion_control'
    ss_file = d / 'tcp_pacing_ss_ratio'
    ca_file = d / 'tcp_pacing_ca_ratio'
    netstat_file = d / 'netstat'

    cc_file.write_text('cubic\n')
    avail_file.write_text('reno cubic bbr\n')
    ss_file.write_text('200\n')
    ca_file.write_text('120\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPSlowStartRetrans TCPFastRetrans TCPSpuriousRTOs TCPRcvCollapsed
TcpExt: 0 100 500 5 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_congestion_control(
        cc_file=str(cc_file),
        avail_file=str(avail_file),
        pacing_ss_file=str(ss_file),
        pacing_ca_file=str(ca_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['current_congestion_control'] == 'cubic'
    assert 'bbr' in res['summary']['available_algorithms']
    assert res['summary']['spurious_rtos'] == 5
    assert res['summary']['receive_collapsed'] == 0

    # Case 2: Receive queue collapsed warning
    coll_netstat = mock_netstat.replace(' 0 100 500 5 0', ' 0 100 500 5 12')
    netstat_file.write_text(coll_netstat)
    res2 = mod.audit_congestion_control(
        cc_file=str(cc_file),
        avail_file=str(avail_file),
        pacing_ss_file=str(ss_file),
        pacing_ca_file=str(ca_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('receive queue collapse' in iss for iss in res2['summary']['issues'])

    # Case 3: High spurious RTOs warning
    rto_netstat = mock_netstat.replace(' 0 100 500 5 0', ' 0 100 500 250 0')
    netstat_file.write_text(rto_netstat)
    res3 = mod.audit_congestion_control(
        cc_file=str(cc_file),
        avail_file=str(avail_file),
        pacing_ss_file=str(ss_file),
        pacing_ca_file=str(ca_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('spurious RTOs' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 106 tests passed!"
