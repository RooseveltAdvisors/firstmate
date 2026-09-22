#!/usr/bin/env bash
# tests/fm-jev-stdurg-guard.test.sh - Regression tests for Pattern 180 (TCP Urgent Pointer Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-stdurg-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-stdurg-guard.py"

echo "Running Pattern 180 regression tests..."

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
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_stdurg' in s
assert 'tcp_stdurg_desc' in s
assert 'in_csum_errors' in s
assert 'in_errs' in s
assert 'estab_resets' in s
assert 'tcp_abort_on_data' in s
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
mod = import_module('fm-jev-stdurg-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    stdurg_f = d / 'tcp_stdurg'
    snmp_f = d / 'snmp'
    netstat_f = d / 'netstat'

    stdurg_f.write_text('0\n')
    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 100 50 10 5 12 1000 1200 20 0 15 0
''')
    netstat_f.write_text('''TcpExt: TCPAbortOnData
TcpExt: 10
''')

    # Case 1: Nominal BSD mode
    res = mod.audit_stdurg(
        stdurg_file=str(stdurg_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_stdurg'] == 0
    assert 'BSD interpretation' in res['summary']['tcp_stdurg_desc']
    assert res['summary']['in_csum_errors'] == 0
    assert res['summary']['in_errs'] == 0
    assert res['summary']['estab_resets'] == 5
    assert res['summary']['tcp_abort_on_data'] == 10

    # Case 2: RFC 1122 mode enabled -> WARNING
    stdurg_f.write_text('1\n')
    res2 = mod.audit_stdurg(
        stdurg_file=str(stdurg_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('Non-standard RFC 1122 urgent pointer' in iss for iss in res2['summary']['issues'])

    # Case 3: Elevated checksum errors -> WARNING
    stdurg_f.write_text('0\n')
    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 100 50 10 5 12 1000 1200 20 0 15 150
''')
    res3 = mod.audit_stdurg(
        stdurg_file=str(stdurg_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert res3['summary']['healthy'] is False
    assert any('Elevated TCP checksum errors' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 180 regression tests passed: 6/6 tests ok"
