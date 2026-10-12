#!/usr/bin/env bash
# tests/fm-jev-plpmtud-guard.test.sh - Regression tests for Pattern 198 (TCP MTU Probing Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-plpmtud-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-plpmtud-guard.py"

echo "Running Pattern 198 regression tests..."

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
assert 'netstat_counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_mtu_probing' in s
assert 'tcp_base_mss' in s
assert 'tcp_mtu_probe_floor' in s
assert 'mtu_probes_failed' in s
assert 'mtu_probes_successful' in s
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
mod = import_module('fm-jev-plpmtud-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    probing_f = d / 'tcp_mtu_probing'
    base_mss_f = d / 'tcp_base_mss'
    floor_f = d / 'tcp_mtu_probe_floor'
    interval_f = d / 'tcp_probe_interval'
    threshold_f = d / 'tcp_probe_threshold'
    netstat_f = d / 'netstat'

    probing_f.write_text('0\n')
    base_mss_f.write_text('1024\n')
    floor_f.write_text('48\n')
    interval_f.write_text('600\n')
    threshold_f.write_text('8\n')
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess TCPTimeouts
TcpExt: 0 0 100
''')

    # Case 1: Nominal
    res = mod.audit_plpmtud(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        probe_interval_file=str(interval_f),
        probe_threshold_file=str(threshold_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_mtu_probing'] == 0
    assert res['summary']['tcp_base_mss'] == 1024
    assert res['summary']['mtu_probes_failed'] == 0

    # Case 2: base_mss out of range -> CRITICAL
    base_mss_f.write_text('32\n')
    res2 = mod.audit_plpmtud(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        probe_interval_file=str(interval_f),
        probe_threshold_file=str(threshold_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('safe range' in iss for iss in res2['summary']['issues'])

    # Case 3: mtup_fail > 1000 -> CRITICAL
    base_mss_f.write_text('1024\n')
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess TCPTimeouts
TcpExt: 1200 50 100
''')
    res3 = mod.audit_plpmtud(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        probe_interval_file=str(interval_f),
        probe_threshold_file=str(threshold_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('persistent MTU probe loss' in iss for iss in res3['summary']['issues'])

    # Case 4: probe_interval < 60 -> WARNING
    netstat_f.write_text('''TcpExt: TCPMTUPFail TCPMTUPSuccess TCPTimeouts
TcpExt: 0 0 100
''')
    interval_f.write_text('30\n')
    res4 = mod.audit_plpmtud(
        mtu_probing_file=str(probing_f),
        base_mss_file=str(base_mss_f),
        probe_floor_file=str(floor_f),
        probe_interval_file=str(interval_f),
        probe_threshold_file=str(threshold_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('probe interval may cause' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 198 regression tests passed: 6/6 tests ok"
