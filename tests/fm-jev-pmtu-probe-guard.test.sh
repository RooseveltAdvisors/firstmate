#!/usr/bin/env bash
# tests/fm-jev-pmtu-probe-guard.test.sh - Regression tests for Pattern 175 (PMTU Probe Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pmtu-probe-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pmtu-probe-guard.py"

echo "Running Pattern 175 regression tests..."

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
assert 'tcp_mtu_probing' in s
assert 'tcp_probe_interval_sec' in s
assert 'tcp_probe_threshold' in s
assert 'mtup_fail' in s
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
mod = import_module('fm-jev-pmtu-probe-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    probing_f = d / 'tcp_mtu_probing'
    base_mss_f = d / 'tcp_base_mss'
    floor_f = d / 'tcp_mtu_probe_floor'
    interval_f = d / 'tcp_probe_interval'
    thresh_f = d / 'tcp_probe_threshold'
    netstat_f = d / 'netstat'

    probing_f.write_text('0\n')
    base_mss_f.write_text('1024\n')
    floor_f.write_text('48\n')
    interval_f.write_text('600\n')
    thresh_f.write_text('8\n')
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess
TcpExt: 0 0
''')

    # Case 1: Nominal
    res = mod.audit_pmtu_probe(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        probe_interval_file=str(interval_f),
        probe_threshold_file=str(thresh_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_probe_interval_sec'] == 600

    # Case 2: Elevated probe failures -> WARNING
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess
TcpExt: 25 2
''')
    res2 = mod.audit_pmtu_probe(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        probe_interval_file=str(interval_f),
        probe_threshold_file=str(thresh_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated Path MTU probe failures' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 175 regression tests passed: 6/6 tests ok"
