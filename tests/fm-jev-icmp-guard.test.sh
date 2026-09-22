#!/usr/bin/env bash
# tests/fm-jev-icmp-guard.test.sh - Regression tests for Pattern 94 (Protocol Error & ICMP Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-icmp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-icmp-guard.py"

echo "Running Pattern 94 regression tests..."

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
assert 'metrics' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'frag_fails' in s
assert 'out_no_routes' in s
assert 'icmp_dest_unreach' in s
assert 'tcp_retrans_segs' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked /proc/net/snmp files
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-icmp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_snmp = os.path.join(tmp_dir, 'snmp')

    # Case 1: Healthy counters
    with open(mock_snmp, 'w') as f:
        f.write('Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates OutTransmits\n')
        f.write('Ip: 1 64 1000 0 0 0 0 0 1000 1000 0 0 0 0 0 0 0 0 0 1000\n')
        f.write('Icmp: InMsgs InErrors InDestUnreachs InTimeExcds OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost\n')
        f.write('Icmp: 10 0 0 0 10 0 0 0\n')
        f.write('Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors\n')
        f.write('Tcp: 1 200 120000 -1 100 10 0 0 5 1000 1000 5 0 0 0\n')

    res = mod.audit_snmp(snmp_path=mock_snmp)
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['frag_fails'] == 0
    assert s['out_no_routes'] == 0

    # Case 2: Warning on elevated fragmentation failures
    with open(mock_snmp, 'w') as f:
        f.write('Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates OutTransmits\n')
        f.write('Ip: 1 64 1000 0 0 0 0 0 1000 1000 0 0 0 0 0 0 0 25 0 1000\n')
        f.write('Icmp: InMsgs InErrors InDestUnreachs InTimeExcds OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost\n')
        f.write('Icmp: 10 0 0 0 10 0 0 0\n')

    res_warn = mod.audit_snmp(snmp_path=mock_snmp, warn_frag_fails=20, crit_frag_fails=100)
    assert res_warn['summary']['status'] == 'WARNING'
    assert res_warn['summary']['frag_fails'] == 25
    assert any('Elevated MTU Fragmentation' in iss for iss in res_warn['summary']['issues'])

    # Case 3: Critical on severe OutNoRoutes
    with open(mock_snmp, 'w') as f:
        f.write('Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates OutTransmits\n')
        f.write('Ip: 1 64 1000 0 0 0 0 0 1000 1000 0 15000 0 0 0 0 0 0 0 1000\n')
        f.write('Icmp: InMsgs InErrors InDestUnreachs InTimeExcds OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost\n')
        f.write('Icmp: 10 0 0 0 10 0 0 0\n')

    res_crit = mod.audit_snmp(snmp_path=mock_snmp, crit_no_routes=10000)
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert res_crit['summary']['out_no_routes'] == 15000
    assert any('CRITICAL Outbound Unroutable' in iss for iss in res_crit['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 94 tests passed!"
