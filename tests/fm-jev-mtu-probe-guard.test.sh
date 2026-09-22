#!/usr/bin/env bash
# tests/fm-jev-mtu-probe-guard.test.sh - Regression tests for Pattern 158 (TCP MTU Probe Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mtu-probe-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mtu-probe-guard.py"

echo "Running Pattern 158 regression tests..."

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
assert 'tcp_mtu_probing' in s
assert 'tcp_base_mss' in s
assert 'tcp_mtu_probe_floor' in s
assert 'mtup_fail' in s
assert 'mtup_success' in s
assert 'total_probes' in s
assert 'fail_ratio_pct' in s
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
mod = import_module('fm-jev-mtu-probe-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    probing_f = d / 'tcp_mtu_probing'
    base_mss_f = d / 'tcp_base_mss'
    floor_f = d / 'tcp_mtu_probe_floor'
    netstat_f = d / 'netstat'

    probing_f.write_text('0\n')
    base_mss_f.write_text('1024\n')
    floor_f.write_text('48\n')
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess
TcpExt: 0 0
''')

    # Case 1: Nominal
    res = mod.audit_mtu_probe(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_mtu_probing'] == 0
    assert res['summary']['tcp_base_mss'] == 1024
    assert res['summary']['mtup_fail'] == 0

    # Case 2: Low base MSS (< 512) -> WARNING
    base_mss_f.write_text('256\n')
    res2 = mod.audit_mtu_probe(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_base_mss is abnormally low' in iss for iss in res2['summary']['issues'])

    # Case 3: High MTU probe failure ratio (> 50%) -> WARNING
    base_mss_f.write_text('1024\n')
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess
TcpExt: 60 20
''')
    res3 = mod.audit_mtu_probe(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Elevated MTU probing failure ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 158 regression tests passed!"
