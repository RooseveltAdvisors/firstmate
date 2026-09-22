#!/usr/bin/env bash
# tests/fm-jev-coalesce-guard.test.sh - Regression tests for Pattern 153 (TCP Coalesce Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-coalesce-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-coalesce-guard.py"

echo "Running Pattern 153 regression tests..."

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
assert 'in_segs' in s
assert 'rcv_coalesce' in s
assert 'backlog_coalesce' in s
assert 'total_coalesced' in s
assert 'coalesce_ratio_pct' in s
assert 'autocorking' in s
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
mod = import_module('fm-jev-coalesce-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    snmp_f = d / 'snmp'

    netstat_f.write_text('''TcpExt: TCPRcvCoalesce TCPBacklogCoalesce TCPAutoCorking
TcpExt: 50000 2500 70000
''')
    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 18000000 3000000 1500000 600000 350 1000000 1500000 300000 0 14000000 0
''')

    # Case 1: Nominal coalescing (52,500 / 1,000,000 = 5.25%)
    res = mod.audit_coalesce(netstat_file=str(netstat_f), snmp_file=str(snmp_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['rcv_coalesce'] == 50000
    assert res['summary']['backlog_coalesce'] == 2500
    assert res['summary']['total_coalesced'] == 52500
    assert res['summary']['coalesce_ratio_pct'] == 5.25

    # Case 2: High traffic but zero coalescing -> WARNING
    netstat_f.write_text('''TcpExt: TCPRcvCoalesce TCPBacklogCoalesce TCPAutoCorking
TcpExt: 0 0 0
''')
    res2 = mod.audit_coalesce(netstat_file=str(netstat_f), snmp_file=str(snmp_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('Zero TCP packet coalescing' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 153 regression tests passed!"
