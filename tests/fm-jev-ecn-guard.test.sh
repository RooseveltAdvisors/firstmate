#!/usr/bin/env bash
# tests/fm-jev-ecn-guard.test.sh - Regression tests for Pattern 159 (TCP ECN Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ecn-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ecn-guard.py"

echo "Running Pattern 159 regression tests..."

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
assert 'tcp_ecn' in s
assert 'tcp_ecn_fallback' in s
assert 'delivered_ce' in s
assert 'in_ce_pkts' in s
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
mod = import_module('fm-jev-ecn-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ecn_f = d / 'tcp_ecn'
    fallback_f = d / 'tcp_ecn_fallback'
    netstat_f = d / 'netstat'

    ecn_f.write_text('2\n')
    fallback_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPDeliveredCE InCEPkts
TcpExt: 118 2510
''')

    # Case 1: Nominal
    res = mod.audit_ecn(
        ecn_file=str(ecn_f),
        fallback_file=str(fallback_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_ecn'] == 2
    assert res['summary']['tcp_ecn_fallback'] == 1
    assert res['summary']['delivered_ce'] == 118
    assert res['summary']['in_ce_pkts'] == 2510

    # Case 2: Disabled ECN -> WARNING
    ecn_f.write_text('0\n')
    res2 = mod.audit_ecn(
        ecn_file=str(ecn_f),
        fallback_file=str(fallback_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_ecn is disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Disabled ECN fallback -> WARNING
    ecn_f.write_text('2\n')
    fallback_f.write_text('0\n')
    res3 = mod.audit_ecn(
        ecn_file=str(ecn_f),
        fallback_file=str(fallback_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('tcp_ecn_fallback is disabled' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 159 regression tests passed!"
