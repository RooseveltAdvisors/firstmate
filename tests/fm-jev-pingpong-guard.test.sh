#!/usr/bin/env bash
# tests/fm-jev-pingpong-guard.test.sh - Regression tests for Pattern 130 (TCP Ping-Pong Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pingpong-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pingpong-guard.py"

echo "Running Pattern 130 regression tests..."

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
assert 'tcp_pingpong_thresh' in s
assert 'delayed_acks' in s
assert 'delayed_ack_lost' in s
assert 'hp_hits' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-pingpong-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    pingpong_f = d / 'tcp_pingpong_thresh'
    sack_delay_f = d / 'tcp_comp_sack_delay_ns'
    sack_nr_f = d / 'tcp_comp_sack_nr'
    netstat_f = d / 'netstat'

    pingpong_f.write_text('1\n')
    sack_delay_f.write_text('1000000\n')
    sack_nr_f.write_text('44\n')

    netstat_f.write_text('''TcpExt: DelayedACKs DelayedACKLocked DelayedACKLost TCPHPHits TCPHPAcks
TcpExt: 1000 10 50 5000 20000
''')

    # Case 1: Nominal
    res = mod.audit_pingpong(
        pingpong_file=str(pingpong_f),
        sack_delay_file=str(sack_delay_f),
        sack_nr_file=str(sack_nr_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_pingpong_thresh'] == 1
    assert res['summary']['delayed_ack_lost_pct'] == 5.0
    assert res['counters']['hp_hits'] == 5000

    # Case 2: pingpong threshold 0 -> WARNING
    pingpong_f.write_text('0\n')
    res2 = mod.audit_pingpong(
        pingpong_file=str(pingpong_f),
        sack_delay_file=str(sack_delay_f),
        sack_nr_file=str(sack_nr_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_pingpong_thresh is 0' in iss for iss in res2['summary']['issues'])
    pingpong_f.write_text('1\n')

    # Case 3: High delayed ACK lost ratio (> 35%) -> NOTICE
    netstat_f.write_text('''TcpExt: DelayedACKs DelayedACKLocked DelayedACKLost TCPHPHits TCPHPAcks
TcpExt: 1000 10 400 5000 20000
''')
    res3 = mod.audit_pingpong(
        pingpong_file=str(pingpong_f),
        sack_delay_file=str(sack_delay_f),
        sack_nr_file=str(sack_nr_f),
        netstat_file=str(netstat_f),
    )
    assert any('delayed-ACK timer expirations' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 130 regression tests passed!"
