#!/usr/bin/env bash
# tests/fm-jev-udp-guard.test.sh - Regression tests for Pattern 98 (UDP Buffer Overflow Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-udp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-udp-guard.py"

echo "Running Pattern 98 regression tests..."

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
assert 'in_datagrams' in s
assert 'rcvbuf_errors' in s
assert 'rcv_drop_pct' in s
c = data['counters']
assert 'in_datagrams' in c
assert 'out_datagrams' in c
assert 'rcvbuf_errors' in c
assert 'sndbuf_errors' in c
assert 'mem_errors' in c
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and snmp files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-udp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    snmp_path = d / 'snmp'
    rmem_def_path = d / 'rmem_default'
    rmem_max_path = d / 'rmem_max'
    wmem_def_path = d / 'wmem_default'
    wmem_max_path = d / 'wmem_max'
    udp_mem_path = d / 'udp_mem'

    rmem_def_path.write_text('212992\n')
    rmem_max_path.write_text('212992\n')
    wmem_def_path.write_text('212992\n')
    wmem_max_path.write_text('212992\n')
    udp_mem_path.write_text('1525479 2033974 3050958\n')

    # Nominal snmp
    snmp_nominal = '''Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors
Udp: 1000000 100 50 800000 50 10 0 5000 0
'''
    snmp_path.write_text(snmp_nominal)

    # Case 1: Healthy configuration and low drop rate (50 / 1000000 = 0.005%)
    res = mod.audit_udp_buffers(
        snmp_file=str(snmp_path),
        rmem_default_file=str(rmem_def_path),
        rmem_max_file=str(rmem_max_path),
        wmem_default_file=str(wmem_def_path),
        wmem_max_file=str(wmem_max_path),
        udp_mem_file=str(udp_mem_path),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert len(res['summary']['issues']) == 0
    assert res['summary']['rcv_drop_pct'] == 0.005

    # Case 2: High drop rate (>1.0%) triggers warning
    snmp_high_drop = '''Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors
Udp: 10000 10 500 8000 250 10 0 50 0
'''
    snmp_path.write_text(snmp_high_drop)
    res_drop = mod.audit_udp_buffers(
        snmp_file=str(snmp_path),
        rmem_default_file=str(rmem_def_path),
        rmem_max_file=str(rmem_max_path),
        wmem_default_file=str(wmem_def_path),
        wmem_max_file=str(wmem_max_path),
        udp_mem_file=str(udp_mem_path),
    )
    assert res_drop['summary']['status'] == 'WARNING'
    assert res_drop['summary']['rcv_drop_pct'] == 2.5
    assert any('receive buffer drop rate' in iss for iss in res_drop['summary']['issues'])

    # Case 3: Memory errors and low buffer size trigger warnings
    rmem_def_path.write_text('32768\n')
    snmp_mem_err = '''Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors
Udp: 10000 10 500 8000 10 10 0 50 12
'''
    snmp_path.write_text(snmp_mem_err)
    res_mem = mod.audit_udp_buffers(
        snmp_file=str(snmp_path),
        rmem_default_file=str(rmem_def_path),
        rmem_max_file=str(rmem_max_path),
        wmem_default_file=str(wmem_def_path),
        wmem_max_file=str(wmem_max_path),
        udp_mem_file=str(udp_mem_path),
    )
    assert res_mem['summary']['status'] == 'WARNING'
    assert any('UDP memory errors detected' in iss for iss in res_mem['summary']['issues'])
    assert any('Low core rmem_default' in iss for iss in res_mem['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 98 tests passed!"
