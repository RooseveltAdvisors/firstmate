#!/usr/bin/env bash
# tests/fm-jev-ofo-guard.test.sh - Regression tests for Pattern 161 (TCP OFO Queue Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ofo-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ofo-guard.py"

echo "Running Pattern 161 regression tests..."

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
assert 'ofo_queue' in s
assert 'ofo_drop' in s
assert 'ofo_merge' in s
assert 'ofo_pruned' in s
assert 'rcv_pruned' in s
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
mod = import_module('fm-jev-ofo-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'

    netstat_f.write_text('''TcpExt: TCPOFOQueue TCPOFODrop TCPOFOMerge OfoPruned RcvPruned
TcpExt: 1000000 10 5000 1 100
''')

    # Case 1: Nominal
    res = mod.audit_ofo(netstat_file=str(netstat_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['ofo_queue'] == 1000000
    assert res['summary']['ofo_drop'] == 10
    assert res['summary']['ofo_merge'] == 5000
    assert res['summary']['ofo_pruned'] == 1
    assert res['summary']['rcv_pruned'] == 100

    # Case 2: High drop count and ratio -> WARNING
    netstat_f.write_text('''TcpExt: TCPOFOQueue TCPOFODrop TCPOFOMerge OfoPruned RcvPruned
TcpExt: 10000 500 100 0 100
''')
    res2 = mod.audit_ofo(netstat_file=str(netstat_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('OFO packet drops' in iss for iss in res2['summary']['issues'])

    # Case 3: High pruned count -> WARNING
    netstat_f.write_text('''TcpExt: TCPOFOQueue TCPOFODrop TCPOFOMerge OfoPruned RcvPruned
TcpExt: 1000000 1 100 600 1000
''')
    res3 = mod.audit_ofo(netstat_file=str(netstat_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('buffer pruning' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 161 regression tests passed!"
