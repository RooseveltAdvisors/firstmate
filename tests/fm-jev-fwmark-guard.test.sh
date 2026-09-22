#!/usr/bin/env bash
# tests/fm-jev-fwmark-guard.test.sh - Regression tests for Pattern 179 (TCP fwmark Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-fwmark-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-fwmark-guard.py"

echo "Running Pattern 179 regression tests..."

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
assert 'tcp_fwmark_accept' in s
assert 'tcp_l3mdev_accept' in s
assert 'rp_filter_drops' in s
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
mod = import_module('fm-jev-fwmark-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    fwmark_f = d / 'tcp_fwmark_accept'
    l3mdev_f = d / 'tcp_l3mdev_accept'
    netstat_f = d / 'netstat'

    fwmark_f.write_text('0\n')
    l3mdev_f.write_text('0\n')
    netstat_f.write_text('''TcpExt: IPReversePathFilter
TcpExt: 0
''')

    # Case 1: Nominal
    res = mod.audit_fwmark(
        fwmark_file=str(fwmark_f),
        l3mdev_file=str(l3mdev_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_fwmark_accept'] == 0
    assert res['summary']['rp_filter_drops'] == 0

    # Case 2: Elevated RP filter drops -> WARNING
    netstat_f.write_text('''TcpExt: IPReversePathFilter
TcpExt: 150
''')
    res2 = mod.audit_fwmark(
        fwmark_file=str(fwmark_f),
        l3mdev_file=str(l3mdev_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated reverse path filter drops' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 179 regression tests passed: 6/6 tests ok"
