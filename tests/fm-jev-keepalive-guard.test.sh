#!/usr/bin/env bash
# tests/fm-jev-keepalive-guard.test.sh - Regression tests for Pattern 148 (TCP Keepalive Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-keepalive-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-keepalive-guard.py"

echo "Running Pattern 148 regression tests..."

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
assert 'ipv4_timers' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_keepalive_time_sec' in s
assert 'tcp_keepalive_intvl_sec' in s
assert 'tcp_keepalive_probes' in s
assert 'active_keepalive_sockets' in s
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
mod = import_module('fm-jev-keepalive-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    tcp_f = d / 'tcp'
    tcp6_f = d / 'tcp6'
    netstat_f = d / 'netstat'
    time_f = d / 'time'
    intvl_f = d / 'intvl'
    probes_f = d / 'probes'

    time_f.write_text('7200\n')
    intvl_f.write_text('75\n')
    probes_f.write_text('9\n')
    tcp6_f.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n')
    tcp_f.write_text('''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:7A69 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 776589420 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F90 0100007F:8A34 01 00000000:00000000 02:0000002A 00000000  1000        0 776589421 1 0000000000000000 100 0 0 10 0
''')
    netstat_f.write_text('''TcpExt: TCPAbortOnTimeout
TcpExt: 12
''')

    # Case 1: Nominal (2.19h < 4.0h)
    res = mod.audit_keepalive(
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        netstat_file=str(netstat_f),
        keepalive_time_file=str(time_f),
        keepalive_intvl_file=str(intvl_f),
        keepalive_probes_file=str(probes_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['active_keepalive_sockets'] == 1
    assert res['summary']['total_sockets'] == 2

    # Case 2: Excessive teardown duration (> 4h) -> WARNING
    time_f.write_text('18000\n')
    res2 = mod.audit_keepalive(
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        netstat_file=str(netstat_f),
        keepalive_time_file=str(time_f),
        keepalive_intvl_file=str(intvl_f),
        keepalive_probes_file=str(probes_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Excessive TCP keepalive teardown duration' in iss for iss in res2['summary']['issues'])

    # Case 3: Probes == 0 -> WARNING
    time_f.write_text('7200\n')
    probes_f.write_text('0\n')
    res3 = mod.audit_keepalive(
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        netstat_file=str(netstat_f),
        keepalive_time_file=str(time_f),
        keepalive_intvl_file=str(intvl_f),
        keepalive_probes_file=str(probes_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('tcp_keepalive_probes is 0' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 148 regression tests passed!"
