#!/usr/bin/env bash
# tests/fm-jev-abort-guard.test.sh - Regression tests for Pattern 120 (TCP Connection Abort Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-abort-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-abort-guard.py"

echo "Running Pattern 120 regression tests..."

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
assert 'tcp_abort_on_overflow' in s
assert 'tcp_retries1' in s
assert 'tcp_retries2' in s
assert 'abort_on_data' in s
assert 'abort_on_close' in s
assert 'abort_on_timeout' in s
assert 'abort_on_memory' in s
assert 'abort_failed' in s
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
mod = import_module('fm-jev-abort-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    overflow_file = d / 'tcp_abort_on_overflow'
    retries1_file = d / 'tcp_retries1'
    retries2_file = d / 'tcp_retries2'
    netstat_file = d / 'netstat'

    overflow_file.write_text('0\n')
    retries1_file.write_text('3\n')
    retries2_file.write_text('15\n')

    mock_netstat = '''TcpExt: EmbryonicRsts TCPAbortOnData TCPAbortOnClose TCPAbortOnMemory TCPAbortOnTimeout TCPAbortOnLinger TCPAbortFailed
TcpExt: 5 1000 50 0 100 0 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_abort(
        overflow_file=str(overflow_file),
        retries1_file=str(retries1_file),
        retries2_file=str(retries2_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_abort_on_overflow'] == 0
    assert res['summary']['abort_on_data'] == 1000
    assert res['summary']['abort_on_memory'] == 0
    assert res['summary']['abort_failed'] == 0

    # Case 2: Enabled abort_on_overflow warning
    overflow_file.write_text('1\n')
    res2 = mod.audit_abort(
        overflow_file=str(overflow_file),
        retries1_file=str(retries1_file),
        retries2_file=str(retries2_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_abort_on_overflow is enabled' in iss for iss in res2['summary']['issues'])
    overflow_file.write_text('0\n')

    # Case 3: Low retries2 limit warning
    retries2_file.write_text('3\n')
    res3 = mod.audit_abort(
        overflow_file=str(overflow_file),
        retries1_file=str(retries1_file),
        retries2_file=str(retries2_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('tcp_retries2 is low' in iss for iss in res3['summary']['issues'])
    retries2_file.write_text('15\n')

    # Case 4: Abort on memory exhaustion warning
    mem_netstat = mock_netstat.replace(' 5 1000 50 0 100 0 0', ' 5 1000 50 12 100 0 0')
    netstat_file.write_text(mem_netstat)
    res4 = mod.audit_abort(
        overflow_file=str(overflow_file),
        retries1_file=str(retries1_file),
        retries2_file=str(retries2_file),
        netstat_file=str(netstat_file),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('TCP connections aborted due to kernel memory exhaustion' in iss for iss in res4['summary']['issues'])

    # Case 5: Elevated failed abort transmissions warning
    fail_netstat = mock_netstat.replace(' 5 1000 50 0 100 0 0', ' 5 1000 50 0 100 0 250')
    netstat_file.write_text(fail_netstat)
    res5 = mod.audit_abort(
        overflow_file=str(overflow_file),
        retries1_file=str(retries1_file),
        retries2_file=str(retries2_file),
        netstat_file=str(netstat_file),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('Elevated failed connection abort transmissions' in iss for iss in res5['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 120 tests passed successfully!"
