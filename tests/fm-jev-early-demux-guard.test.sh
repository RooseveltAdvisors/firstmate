#!/usr/bin/env bash
# tests/fm-jev-early-demux-guard.test.sh - Regression tests for Pattern 129 (Early Demux Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-early-demux-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-early-demux-guard.py"

echo "Running Pattern 129 regression tests..."

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
assert 'ip_early_demux' in s
assert 'tcp_early_demux' in s
assert 'in_receives' in s
assert 'in_delivers' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/snmp files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-early-demux-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ip_f = d / 'ip_early_demux'
    tcp_f = d / 'tcp_early_demux'
    udp_f = d / 'udp_early_demux'
    snmp_f = d / 'snmp'

    ip_f.write_text('1\n')
    tcp_f.write_text('1\n')
    udp_f.write_text('1\n')

    snmp_f.write_text('''Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates OutTransmits
Ip: 1 64 500000 0 0 10 0 5 499980 400000 0 0 0 0 0 0 0 0 0 400000
''')

    # Case 1: Nominal
    res = mod.audit_early_demux(
        ip_early_file=str(ip_f),
        tcp_early_file=str(tcp_f),
        udp_early_file=str(udp_f),
        snmp_file=str(snmp_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_early_demux'] == 1
    assert res['summary']['ip_early_demux'] == 1
    assert res['counters']['in_receives'] == 500000

    # Case 2: TCP early demux disabled -> WARNING
    tcp_f.write_text('0\n')
    res2 = mod.audit_early_demux(
        ip_early_file=str(ip_f),
        tcp_early_file=str(tcp_f),
        udp_early_file=str(udp_f),
        snmp_file=str(snmp_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('TCP early demux is disabled' in iss for iss in res2['summary']['issues'])
    tcp_f.write_text('1\n')

    # Case 3: Ingress discard spike -> WARNING
    bad_snmp = '''Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates OutTransmits
Ip: 1 64 500000 0 0 10 0 65000 400000 400000 0 0 0 0 0 0 0 0 0 400000
'''
    snmp_f.write_text(bad_snmp)
    res3 = mod.audit_early_demux(
        ip_early_file=str(ip_f),
        tcp_early_file=str(tcp_f),
        udp_early_file=str(udp_f),
        snmp_file=str(snmp_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('discards' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 129 regression tests passed!"
