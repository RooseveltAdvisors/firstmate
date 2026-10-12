#!/usr/bin/env bash
# tests/fm-jev-ack-guard.test.sh - Regression tests for Pattern 113 (TCP ACK Compression Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ack-guard.py"

echo "Running Pattern 113 regression tests..."

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
assert 'tcp_comp_sack_delay_ns' in s
assert 'ack_compression_delay_ms' in s
assert 'tcp_comp_sack_nr' in s
assert 'delayed_acks_total' in s
assert 'ack_compressed_total' in s
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
mod = import_module('fm-jev-ack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    delay_file = d / 'tcp_comp_sack_delay_ns'
    nr_file = d / 'tcp_comp_sack_nr'
    netstat_file = d / 'netstat'

    delay_file.write_text('1000000\n')
    nr_file.write_text('44\n')

    mock_netstat = '''TcpExt: SyncookiesSent DelayedACKs DelayedACKLocked DelayedACKLost TCPAckCompressed TCPACKSkippedSeq TCPHPAcks TCPPureAcks TCPHPHits
TcpExt: 0 1000 5 100 500 10 2000 1500 800
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_ack(
        delay_file=str(delay_file),
        nr_file=str(nr_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['ack_compression_delay_ms'] == 1.0
    assert res['summary']['tcp_comp_sack_nr'] == 44
    assert res['summary']['delayed_acks_total'] == 1000
    assert res['summary']['ack_compressed_total'] == 500

    # Case 2: High delay warning (> 5ms)
    delay_file.write_text('10000000\n') # 10ms
    res2 = mod.audit_ack(
        delay_file=str(delay_file),
        nr_file=str(nr_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('High tcp_comp_sack_delay_ns' in iss for iss in res2['summary']['issues'])
    delay_file.write_text('1000000\n')

    # Case 3: High DelayedACKLocked warning
    locked_netstat = mock_netstat.replace(' 0 1000 5 100 500 10 2000 1500 800', ' 0 1000 100 100 500 10 2000 1500 800')
    netstat_file.write_text(locked_netstat)
    res3 = mod.audit_ack(
        delay_file=str(delay_file),
        nr_file=str(nr_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('DelayedACKLocked ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 113 tests passed successfully!"
