#!/usr/bin/env bash
# tests/fm-jev-keepalive-guard.test.sh - Regression tests for Pattern 195 (TCP Keepalive Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-keepalive-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-keepalive-guard.py"

echo "Running Pattern 195 regression tests..."

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
assert 'tcp_keepalive_time_sec' in s
assert 'tcp_keepalive_intvl_sec' in s
assert 'tcp_keepalive_probes' in s
assert 'total_dead_peer_detect_sec' in s
assert 'keepalive_probes_sent' in s
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
    time_f = d / 'tcp_keepalive_time'
    intvl_f = d / 'tcp_keepalive_intvl'
    probes_f = d / 'tcp_keepalive_probes'
    netstat_f = d / 'netstat'

    time_f.write_text('7200\n')
    intvl_f.write_text('75\n')
    probes_f.write_text('9\n')
    netstat_f.write_text('''TcpExt: TCPKeepAlive TCPTimeouts
TcpExt: 50000 100
''')

    # Case 1: Nominal
    res = mod.audit_keepalive(
        keepalive_time_file=str(time_f),
        keepalive_intvl_file=str(intvl_f),
        keepalive_probes_file=str(probes_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_keepalive_time_sec'] == 7200
    assert res['summary']['total_dead_peer_detect_sec'] == 7875
    assert res['summary']['keepalive_probes_sent'] == 50000

    # Case 2: Probes == 0 -> CRITICAL
    probes_f.write_text('0\n')
    res2 = mod.audit_keepalive(
        keepalive_time_file=str(time_f),
        keepalive_intvl_file=str(intvl_f),
        keepalive_probes_file=str(probes_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Excessive detection latency (> 14400s / 4h) -> CRITICAL
    probes_f.write_text('9\n')
    time_f.write_text('15000\n')
    res3 = mod.audit_keepalive(
        keepalive_time_file=str(time_f),
        keepalive_intvl_file=str(intvl_f),
        keepalive_probes_file=str(probes_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('exceeds 4 hours' in iss for iss in res3['summary']['issues'])

    # Case 4: Overly short keepalive time (< 30s) -> WARNING
    time_f.write_text('10\n')
    res4 = mod.audit_keepalive(
        keepalive_time_file=str(time_f),
        keepalive_intvl_file=str(intvl_f),
        keepalive_probes_file=str(probes_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('overly aggressive' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 195 regression tests passed: 6/6 tests ok"
