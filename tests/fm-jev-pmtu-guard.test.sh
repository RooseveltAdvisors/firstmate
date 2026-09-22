#!/usr/bin/env bash
# tests/fm-jev-pmtu-guard.test.sh - Regression tests for Pattern 103 (MTU & PMTUD Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pmtu-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pmtu-guard.py"

echo "Running Pattern 103 regression tests..."

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
assert 'interfaces' in data
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'pmtu_discovery_enabled' in s
assert 'tcp_mtu_probing_mode' in s
assert 'tcp_base_mss_bytes' in s
assert 'interface_count' in s
assert 'mtu_probe_failures' in s
assert 'mtu_probe_successes' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctls, net dir, and /proc/net/netstat
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-pmtu-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    probing_file = d / 'tcp_mtu_probing'
    no_disc_file = d / 'ip_no_pmtu_disc'
    base_mss_file = d / 'tcp_base_mss'
    net_dir = d / 'net'
    netstat_file = d / 'netstat'

    net_dir.mkdir()
    eth0 = net_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'mtu').write_text('1500\n')
    (eth0 / 'operstate').write_text('up\n')

    lo = net_dir / 'lo'
    lo.mkdir()
    (lo / 'mtu').write_text('65536\n')
    (lo / 'operstate').write_text('unknown\n')

    probing_file.write_text('1\n')
    no_disc_file.write_text('0\n')
    base_mss_file.write_text('1024\n')

    mock_netstat = '''TcpExt: SyncookiesSent SyncookiesRecv TCPMTUPFail TCPMTUPSuccess
TcpExt: 0 0 0 5
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_pmtu(
        mtu_probing_file=str(probing_file),
        no_pmtu_disc_file=str(no_disc_file),
        base_mss_file=str(base_mss_file),
        net_dir=str(net_dir),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['pmtu_discovery_enabled'] is True
    assert res['summary']['tcp_mtu_probing_mode'] == 1
    assert res['summary']['interface_count'] == 2
    assert res['summary']['mtu_probe_successes'] == 5
    assert res['summary']['mtu_probe_failures'] == 0

    # Case 2: PMTU Discovery disabled
    no_disc_file.write_text('1\n')
    res2 = mod.audit_pmtu(
        mtu_probing_file=str(probing_file),
        no_pmtu_disc_file=str(no_disc_file),
        base_mss_file=str(base_mss_file),
        net_dir=str(net_dir),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('ip_no_pmtu_disc=1' in iss for iss in res2['summary']['issues'])
    no_disc_file.write_text('0\n')

    # Case 3: Sub-minimum MTU on non-loopback interface
    (eth0 / 'mtu').write_text('1200\n')
    res3 = mod.audit_pmtu(
        mtu_probing_file=str(probing_file),
        no_pmtu_disc_file=str(no_disc_file),
        base_mss_file=str(base_mss_file),
        net_dir=str(net_dir),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('sub-minimum IPv6 MTU' in iss for iss in res3['summary']['issues'])
    (eth0 / 'mtu').write_text('1500\n')

    # Case 4: High MTU probing failures
    fail_netstat = '''TcpExt: SyncookiesSent SyncookiesRecv TCPMTUPFail TCPMTUPSuccess
TcpExt: 0 0 25 2
'''
    netstat_file.write_text(fail_netstat)
    res4 = mod.audit_pmtu(
        mtu_probing_file=str(probing_file),
        no_pmtu_disc_file=str(no_disc_file),
        base_mss_file=str(base_mss_file),
        net_dir=str(net_dir),
        netstat_file=str(netstat_file),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('path MTU blackhole detected' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 103 tests passed!"
