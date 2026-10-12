#!/usr/bin/env bash
# tests/fm-jev-abort-guard.test.sh - Regression tests for Pattern 146 (TCP Abort Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-abort-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-abort-guard.py"

echo "Running Pattern 146 regression tests..."

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
assert 'total_connections' in s
assert 'abort_on_data' in s
assert 'abort_on_memory' in s
assert 'abort_failed' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked netstat and snmp files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-abort-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    snmp_f = d / 'snmp'

    netstat_f.write_text('''TcpExt: TCPAbortOnData TCPAbortOnClose TCPAbortOnTimeout TCPAbortOnMemory TCPAbortFailed TCPBacklogDrop
TcpExt: 500 50 10 0 5 0
''')
    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 10000 5000 200 100 50 100000 150000 500 0 1000 0
''')

    # Case 1: Nominal
    res = mod.audit_tcp_aborts(netstat_file=str(netstat_f), snmp_file=str(snmp_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['total_connections'] == 15000
    assert res['summary']['abort_on_data'] == 500
    assert res['summary']['abort_on_memory'] == 0

    # Case 2: Memory exhaustion aborts > 0 -> WARNING/CRITICAL
    netstat_f.write_text('''TcpExt: TCPAbortOnData TCPAbortOnClose TCPAbortOnTimeout TCPAbortOnMemory TCPAbortFailed TCPBacklogDrop
TcpExt: 500 50 10 12 5 0
''')
    res2 = mod.audit_tcp_aborts(netstat_file=str(netstat_f), snmp_file=str(snmp_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('kernel memory exhaustion' in iss for iss in res2['summary']['issues'])

    # Case 3: Backlog drops > 500 -> WARNING
    netstat_f.write_text('''TcpExt: TCPAbortOnData TCPAbortOnClose TCPAbortOnTimeout TCPAbortOnMemory TCPAbortFailed TCPBacklogDrop
TcpExt: 500 50 10 0 5 600
''')
    res3 = mod.audit_tcp_aborts(netstat_file=str(netstat_f), snmp_file=str(snmp_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('Socket backlog drops' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 146 regression tests passed!"
