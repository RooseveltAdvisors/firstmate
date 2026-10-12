#!/usr/bin/env bash
# tests/fm-jev-synack-guard.test.sh - Regression tests for Pattern 107 (TCP SYN-ACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-synack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-synack-guard.py"

echo "Running Pattern 107 regression tests..."

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
assert 'tcp_synack_retries' in s
assert 'estimated_synack_hold_sec' in s
assert 'abort_failed_events' in s
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
mod = import_module('fm-jev-synack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    synack_file = d / 'tcp_synack_retries'
    syn_file = d / 'tcp_syn_retries'
    overflow_file = d / 'tcp_abort_on_overflow'
    orphan_file = d / 'tcp_orphan_retries'
    netstat_file = d / 'netstat'

    synack_file.write_text('5\n')
    syn_file.write_text('6\n')
    overflow_file.write_text('0\n')
    orphan_file.write_text('0\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPAbortOnSyn TCPAbortOnData TCPAbortOnClose TCPAbortOnMemory TCPAbortOnTimeout TCPAbortFailed
TcpExt: 0 0 100 10 0 5 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_synack(
        synack_file=str(synack_file),
        syn_file=str(syn_file),
        overflow_file=str(overflow_file),
        orphan_file=str(orphan_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_synack_retries'] == 5
    assert res['summary']['estimated_synack_hold_sec'] == 31
    assert res['summary']['abort_failed_events'] == 0

    # Case 2: Memory abort warning
    mem_netstat = mock_netstat.replace(' 0 0 100 10 0 5 0', ' 0 0 100 10 3 5 0')
    netstat_file.write_text(mem_netstat)
    res2 = mod.audit_synack(
        synack_file=str(synack_file),
        syn_file=str(syn_file),
        overflow_file=str(overflow_file),
        orphan_file=str(orphan_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('memory exhaustion' in iss for iss in res2['summary']['issues'])

    # Case 3: Failed abort RST warning
    fail_netstat = mock_netstat.replace(' 0 0 100 10 0 5 0', ' 0 0 100 10 0 5 15')
    netstat_file.write_text(fail_netstat)
    res3 = mod.audit_synack(
        synack_file=str(synack_file),
        syn_file=str(syn_file),
        overflow_file=str(overflow_file),
        orphan_file=str(orphan_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('RST abort failures' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 107 tests passed!"
