#!/usr/bin/env bash
# tests/fm-jev-keepalive-guard.test.sh - Regression tests for Pattern 101 (TCP Keepalive Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-keepalive-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-keepalive-guard.py"

echo "Running Pattern 101 regression tests..."

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
assert 'details' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_keepalive_time_sec' in s
assert 'total_dead_peer_latency_sec' in s
assert 'total_tcp_sockets' in s
assert 'keepalive_timer_active' in s
assert 'retrans_timer_active' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and tcp timer files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-keepalive-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    time_path = d / 'tcp_keepalive_time'
    intvl_path = d / 'tcp_keepalive_intvl'
    probes_path = d / 'tcp_keepalive_probes'
    tcp_path = d / 'tcp'
    tcp6_path = d / 'tcp6'

    time_path.write_text('300\n')
    intvl_path.write_text('30\n')
    probes_path.write_text('5\n')

    # Mock tcp table
    mock_tcp = '''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1539 0100007F:1538 01 00000000:00000000 02:00001000 00000000  1000        0 12346 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1540 0100007F:1538 01 00000000:00000000 01:00000500 00000002  1000        0 12347 1 0000000000000000 100 0 0 10 0
'''
    tcp_path.write_text(mock_tcp)
    tcp6_path.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n')

    # Case 1: Healthy custom low-latency keepalive
    res = mod.audit_keepalive(
        keepalive_time_file=str(time_path),
        keepalive_intvl_file=str(intvl_path),
        keepalive_probes_file=str(probes_path),
        tcp_file=str(tcp_path),
        tcp6_file=str(tcp6_path),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_keepalive_time_sec'] == 300
    assert res['summary']['total_dead_peer_latency_sec'] == 450
    assert res['summary']['total_tcp_sockets'] == 3
    assert res['summary']['keepalive_timer_active'] == 1
    assert res['summary']['retrans_timer_active'] == 1

    # Case 2: Excessive keepalive time (e.g. 7200s default) triggers warning
    time_path.write_text('7200\n')
    res_high = mod.audit_keepalive(
        keepalive_time_file=str(time_path),
        keepalive_intvl_file=str(intvl_path),
        keepalive_probes_file=str(probes_path),
        tcp_file=str(tcp_path),
        tcp6_file=str(tcp6_path),
    )
    assert res_high['summary']['status'] == 'WARNING'
    assert any('High tcp_keepalive_time' in iss for iss in res_high['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 101 tests passed!"
