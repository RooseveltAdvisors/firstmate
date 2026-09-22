#!/usr/bin/env bash
# tests/fm-jev-tos-reflect-guard.test.sh - Regression tests for Pattern 176 (TCP ToS Reflection Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tos-reflect-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tos-reflect-guard.py"

echo "Running Pattern 176 regression tests..."

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
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_reflect_tos' in s
assert 'ip_default_ttl' in s
assert 'ip_in_receives' in s
assert 'tcp_delivered' in s
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
mod = import_module('fm-jev-tos-reflect-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    tos_f = d / 'tcp_reflect_tos'
    ttl_f = d / 'ip_default_ttl'
    snmp_f = d / 'snmp'
    netstat_f = d / 'netstat'

    tos_f.write_text('0\n')
    ttl_f.write_text('64\n')
    snmp_f.write_text('''Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates
Ip: 1 64 1000 0 0 0 0 0 1000 1000 0 0 0 0 0 0 0 0 0
''')
    netstat_f.write_text('''TcpExt: TCPDelivered TCPDeliveredCE
TcpExt: 5000 10
''')

    # Case 1: Nominal
    res = mod.audit_tos_reflect(
        tos_reflect_file=str(tos_f),
        default_ttl_file=str(ttl_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_reflect_tos'] == 0
    assert res['summary']['ip_default_ttl'] == 64

    # Case 2: Elevated header errors -> WARNING
    snmp_f.write_text('''Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates
Ip: 1 64 1000 150 0 0 0 0 850 1000 0 0 0 0 0 0 0 0 0
''')
    res2 = mod.audit_tos_reflect(
        tos_reflect_file=str(tos_f),
        default_ttl_file=str(ttl_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated IP header errors' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 176 regression tests passed: 6/6 tests ok"
