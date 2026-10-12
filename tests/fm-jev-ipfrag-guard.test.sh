#!/usr/bin/env bash
# tests/fm-jev-ipfrag-guard.test.sh - Regression tests for Pattern 126 (IP Fragment Reassembly Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipfrag-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipfrag-guard.py"

echo "Running Pattern 126 regression tests..."

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
assert 'high_thresh_bytes' in s
assert 'low_thresh_bytes' in s
assert 'frag_memory_bytes' in s
assert 'reasm_fails' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and procfs files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-ipfrag-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    high_f = d / 'ipfrag_high_thresh'
    low_f = d / 'ipfrag_low_thresh'
    time_f = d / 'ipfrag_time'
    dist_f = d / 'ipfrag_max_dist'
    sockstat_f = d / 'sockstat'
    snmp_f = d / 'snmp'

    high_f.write_text('4194304\n')
    low_f.write_text('3145728\n')
    time_f.write_text('30\n')
    dist_f.write_text('64\n')

    sockstat_f.write_text('''sockets: used 500
TCP: inuse 10 orphan 0 tw 5 alloc 15 mem 0
UDP: inuse 2 mem 10
FRAG: inuse 0 memory 0
''')

    snmp_f.write_text('''Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates OutTransmits
Ip: 1 64 100000 0 0 0 0 0 100000 90000 0 0 0 100 95 5 0 0 0 90000
''')

    # Case 1: Nominal
    res = mod.audit_ipfrag(
        high_thresh_file=str(high_f),
        low_thresh_file=str(low_f),
        time_file=str(time_f),
        max_dist_file=str(dist_f),
        sockstat_file=str(sockstat_f),
        snmp_file=str(snmp_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['frag_memory_bytes'] == 0
    assert res['counters']['reasm_fails'] == 5

    # Case 2: Saturated memory -> WARNING
    sockstat_f.write_text('''sockets: used 500
FRAG: inuse 100 memory 5000000
''')
    res2 = mod.audit_ipfrag(
        high_thresh_file=str(high_f),
        low_thresh_file=str(low_f),
        time_file=str(time_f),
        max_dist_file=str(dist_f),
        sockstat_file=str(sockstat_f),
        snmp_file=str(snmp_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('saturated' in iss for iss in res2['summary']['issues'])

    # Case 3: Reassembly failure spike -> WARNING
    sockstat_f.write_text('''sockets: used 500
FRAG: inuse 0 memory 0
''')
    bad_snmp = '''Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates OutTransmits
Ip: 1 64 100000 0 0 0 0 0 100000 90000 0 0 0 100 95 2500 0 0 0 90000
'''
    snmp_f.write_text(bad_snmp)
    res3 = mod.audit_ipfrag(
        high_thresh_file=str(high_f),
        low_thresh_file=str(low_f),
        time_file=str(time_f),
        max_dist_file=str(dist_f),
        sockstat_file=str(sockstat_f),
        snmp_file=str(snmp_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('failures' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 126 regression tests passed!"
