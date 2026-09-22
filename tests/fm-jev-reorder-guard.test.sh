#!/usr/bin/env bash
# tests/fm-jev-reorder-guard.test.sh - Regression tests for Pattern 188 (TCP Packet Reordering Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-reorder-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-reorder-guard.py"

echo "Running Pattern 188 regression tests..."

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
assert 'tcp_reordering' in s
assert 'tcp_max_reordering' in s
assert 'ofo_queue' in s
assert 'ofo_drop' in s
assert 'sack_reorder' in s
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
mod = import_module('fm-jev-reorder-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    reorder_f = d / 'tcp_reordering'
    max_reorder_f = d / 'tcp_max_reordering'
    netstat_f = d / 'netstat'

    reorder_f.write_text('3\n')
    max_reorder_f.write_text('300\n')
    netstat_f.write_text('''TcpExt: TCPOFOQueue TCPOFODrop TCPOFOMerge TCPSACKReorder TCPRenoReorder TCPTSReorder
TcpExt: 10000 0 500 100 0 10
''')

    # Case 1: Nominal
    res = mod.audit_reordering(
        reordering_file=str(reorder_f),
        max_reordering_file=str(max_reorder_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_reordering'] == 3
    assert res['summary']['tcp_max_reordering'] == 300
    assert res['summary']['ofo_queue'] == 10000
    assert res['summary']['ofo_drop'] == 0

    # Case 2: Sub-optimal reordering (< 3) -> WARNING
    reorder_f.write_text('1\n')
    res2 = mod.audit_reordering(
        reordering_file=str(reorder_f),
        max_reordering_file=str(max_reorder_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('sub-optimal' in iss for iss in res2['summary']['issues'])

    # Case 3: max_reordering < reordering -> WARNING
    reorder_f.write_text('50\n')
    max_reorder_f.write_text('20\n')
    res3 = mod.audit_reordering(
        reordering_file=str(reorder_f),
        max_reordering_file=str(max_reorder_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('less than' in iss for iss in res3['summary']['issues'])

    # Case 4: High OFO drops -> WARNING
    reorder_f.write_text('3\n')
    max_reorder_f.write_text('300\n')
    netstat_f.write_text('''TcpExt: TCPOFOQueue TCPOFODrop TCPOFOMerge TCPSACKReorder TCPRenoReorder TCPTSReorder
TcpExt: 10000 250 500 100 0 10
''')
    res4 = mod.audit_reordering(
        reordering_file=str(reorder_f),
        max_reordering_file=str(max_reorder_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('drops detected' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 188 regression tests passed: 6/6 tests ok"
