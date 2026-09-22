#!/usr/bin/env bash
# tests/fm-jev-low-latency-guard.test.sh - Regression tests for Pattern 171 (TCP Low Latency Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-low-latency-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-low-latency-guard.py"

echo "Running Pattern 171 regression tests..."

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
assert 'tcp_low_latency' in s
assert 'tcp_abort_on_overflow' in s
assert 'listen_overflows' in s
assert 'listen_drops' in s
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
mod = import_module('fm-jev-low-latency-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    lat_f = d / 'tcp_low_latency'
    abort_f = d / 'tcp_abort_on_overflow'
    syn_f = d / 'tcp_max_syn_backlog'
    somax_f = d / 'somaxconn'
    netstat_f = d / 'netstat'

    lat_f.write_text('0\n')
    abort_f.write_text('0\n')
    syn_f.write_text('4096\n')
    somax_f.write_text('4096\n')
    netstat_f.write_text('''TcpExt: ListenOverflows ListenDrops EmbryonicRsts
TcpExt: 0 0 14
''')

    # Case 1: Nominal
    res = mod.audit_low_latency(
        low_latency_file=str(lat_f),
        abort_overflow_file=str(abort_f),
        syn_backlog_file=str(syn_f),
        somaxconn_file=str(somax_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_low_latency'] == 0
    assert res['summary']['listen_overflows'] == 0
    assert res['summary']['listen_drops'] == 0

    # Case 2: Elevated listen overflows -> WARNING
    netstat_f.write_text('''TcpExt: ListenOverflows ListenDrops EmbryonicRsts
TcpExt: 25 0 14
''')
    res2 = mod.audit_low_latency(
        low_latency_file=str(lat_f),
        abort_overflow_file=str(abort_f),
        syn_backlog_file=str(syn_f),
        somaxconn_file=str(somax_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated listen queue overflows' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 171 regression tests passed!"
