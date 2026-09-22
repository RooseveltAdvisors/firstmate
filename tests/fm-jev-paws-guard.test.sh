#!/usr/bin/env bash
# tests/fm-jev-paws-guard.test.sh - Regression tests for Pattern 109 (TCP TIME-WAIT & PAWS Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-paws-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-paws-guard.py"

echo "Running Pattern 109 regression tests..."

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
assert 'tcp_tw_reuse' in s
assert 'tcp_timestamps' in s
assert 'paws_estab_drops' in s
assert 'tw_overflow_events' in s
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
mod = import_module('fm-jev-paws-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    tw_reuse_file = d / 'tcp_tw_reuse'
    timestamps_file = d / 'tcp_timestamps'
    rfc1337_file = d / 'tcp_rfc1337'
    max_tw_buckets_file = d / 'tcp_max_tw_buckets'
    netstat_file = d / 'netstat'

    tw_reuse_file.write_text('2\n')
    timestamps_file.write_text('1\n')
    rfc1337_file.write_text('0\n')
    max_tw_buckets_file.write_text('262144\n')

    mock_netstat = '''TcpExt: SyncookiesSent TW TWRecycled TWKilled PAWSActive PAWSEstab PAWSOldAck PAWSTimewait TCPACKSkippedPAWS TCPTimeWaitOverflow
TcpExt: 0 1000 50 0 0 10 2 0 5 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_paws(
        tw_reuse_file=str(tw_reuse_file),
        timestamps_file=str(timestamps_file),
        rfc1337_file=str(rfc1337_file),
        max_tw_buckets_file=str(max_tw_buckets_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_tw_reuse'] == 2
    assert res['summary']['tcp_timestamps'] is True
    assert res['summary']['paws_estab_drops'] == 10
    assert res['summary']['tw_overflow_events'] == 0

    # Case 2: Inconsistent config (reuse enabled, timestamps disabled)
    timestamps_file.write_text('0\n')
    res2 = mod.audit_paws(
        tw_reuse_file=str(tw_reuse_file),
        timestamps_file=str(timestamps_file),
        rfc1337_file=str(rfc1337_file),
        max_tw_buckets_file=str(max_tw_buckets_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Inconsistent TCP configuration' in iss for iss in res2['summary']['issues'])
    timestamps_file.write_text('1\n')

    # Case 3: TIME-WAIT Overflow warning
    overflow_netstat = mock_netstat.replace(' 0 1000 50 0 0 10 2 0 5 0', ' 0 1000 50 0 0 10 2 0 5 42')
    netstat_file.write_text(overflow_netstat)
    res3 = mod.audit_paws(
        tw_reuse_file=str(tw_reuse_file),
        timestamps_file=str(timestamps_file),
        rfc1337_file=str(rfc1337_file),
        max_tw_buckets_file=str(max_tw_buckets_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('TIME-WAIT table overflows' in iss for iss in res3['summary']['issues'])

    # Case 4: Excessive PAWS Established drops warning
    paws_netstat = mock_netstat.replace(' 0 1000 50 0 0 10 2 0 5 0', ' 0 1000 50 0 0 60000 2 0 5 0')
    netstat_file.write_text(paws_netstat)
    res4 = mod.audit_paws(
        tw_reuse_file=str(tw_reuse_file),
        timestamps_file=str(timestamps_file),
        rfc1337_file=str(rfc1337_file),
        max_tw_buckets_file=str(max_tw_buckets_file),
        netstat_file=str(netstat_file),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('Elevated PAWS drops' in iss for iss in res4['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 109 tests passed successfully!"
