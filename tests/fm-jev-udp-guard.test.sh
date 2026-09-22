#!/usr/bin/env bash
# tests/fm-jev-udp-guard.test.sh - Regression tests for Pattern 203 (UDP Datagram Buffer Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-udp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-udp-guard.py"

echo "Running Pattern 203 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['in_datagrams'], int)
assert isinstance(s['rcvbuf_errors'], int)
assert isinstance(s['sndbuf_errors'], int)
assert isinstance(s['mem_errors'], int)
assert isinstance(s['raw_sockets_total'], int)
assert isinstance(s['udp_sockets_active'], int)
assert isinstance(s['issues'], list)
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
mod = import_module('fm-jev-udp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sys_dir = d / 'ipv4'
    sys_dir.mkdir()
    snmp_f = d / 'snmp'
    snmp6_f = d / 'snmp6'
    raw_f = d / 'raw'
    raw6_f = d / 'raw6'
    udp_f = d / 'udp'
    udp6_f = d / 'udp6'

    (sys_dir / 'udp_mem').write_text('1000 2000 3000\n')
    (sys_dir / 'udp_rmem_min').write_text('4096\n')
    (sys_dir / 'udp_wmem_min').write_text('4096\n')

    # Mock snmp
    snmp_f.write_text(
        'Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors\n'
        'Udp: 10000 10 5 9000 5 0 0 100 0\n'
    )
    snmp6_f.write_text(
        'Udp6InDatagrams\t500\n'
        'Udp6NoPorts\t0\n'
        'Udp6InErrors\t0\n'
        'Udp6OutDatagrams\t500\n'
        'Udp6RcvbufErrors\t0\n'
        'Udp6SndbufErrors\t0\n'
        'Udp6InCsumErrors\t0\n'
        'Udp6IgnoredMulti\t0\n'
        'Udp6MemErrors\t0\n'
    )
    raw_f.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n')
    raw6_f.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n')
    udp_f.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n  0: 00000000:0035 ...\n')
    udp6_f.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n')

    rep = mod.audit_udp(
        proc_snmp=str(snmp_f),
        proc_snmp6=str(snmp6_f),
        proc_sys_ipv4=str(sys_dir),
        proc_raw=str(raw_f),
        proc_raw6=str(raw6_f),
        proc_udp=str(udp_f),
        proc_udp6=str(udp6_f)
    )
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['in_datagrams'] == 10500
    assert s['out_datagrams'] == 9500
    assert s['rcvbuf_errors'] == 5
    assert s['mem_errors'] == 0
    assert s['raw_sockets_total'] == 0
    assert s['udp_sockets_active'] == 1

    # Test MemErrors -> CRITICAL
    snmp_f.write_text(
        'Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors\n'
        'Udp: 10000 10 5 9000 5 0 0 100 2\n'
    )
    rep2 = mod.audit_udp(
        proc_snmp=str(snmp_f),
        proc_snmp6=str(snmp6_f),
        proc_sys_ipv4=str(sys_dir),
        proc_raw=str(raw_f),
        proc_raw6=str(raw6_f),
        proc_udp=str(udp_f),
        proc_udp6=str(udp6_f)
    )
    assert rep2['summary']['status'] == 'CRITICAL'
    assert rep2['summary']['healthy'] is False
    assert rep2['summary']['mem_errors'] == 2

    # Test Raw Sockets > 5 -> CRITICAL
    raw_lines = ['  sl  local_address ...'] + [f'  {i}: 00000000:0000 ...' for i in range(6)]
    raw_f.write_text('\n'.join(raw_lines) + '\n')
    rep3 = mod.audit_udp(
        proc_snmp=str(snmp_f),
        proc_snmp6=str(snmp6_f),
        proc_sys_ipv4=str(sys_dir),
        proc_raw=str(raw_f),
        proc_raw6=str(raw6_f),
        proc_udp=str(udp_f),
        proc_udp6=str(udp6_f)
    )
    assert rep3['summary']['status'] == 'CRITICAL'
    assert rep3['summary']['raw_sockets_total'] == 6
"
echo "ok - mocked unit tests pass"

echo "All Pattern 203 tests passed successfully."
