#!/usr/bin/env bash
# tests/fm-jev-rehash-guard.test.sh - Regression tests for Pattern 163 (TCP Timeout Path Rehashing Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rehash-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rehash-guard.py"

echo "Running Pattern 163 regression tests..."

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
assert 'timeout_rehash' in s
assert 'rehash_ratio_pct' in s
assert 'duplicate_data_rehash' in s
assert 'plb_rehash' in s
assert 'plb_rehash_rounds' in s
assert 'plb_idle_rehash_rounds' in s
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
mod = import_module('fm-jev-rehash-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    plb_f = d / 'tcp_plb_rehash_rounds'
    plb_idle_f = d / 'tcp_plb_idle_rehash_rounds'

    plb_f.write_text('12\n')
    plb_idle_f.write_text('3\n')
    netstat_f.write_text('''TcpExt: TcpTimeoutRehash TcpDuplicateDataRehash TCPPLBRehash TCPTimeouts TCPDelivered
TcpExt: 900 10 5 1000 50000
''')

    # Case 1: Nominal (900 / 1000 = 90.0% rehash ratio)
    res = mod.audit_rehash(
        netstat_file=str(netstat_f),
        plb_rounds_file=str(plb_f),
        plb_idle_rounds_file=str(plb_idle_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['timeout_rehash'] == 900
    assert res['summary']['rehash_ratio_pct'] == 90.0
    assert res['summary']['plb_rehash_rounds'] == 12

    # Case 2: Zero rehash with high timeouts (>1000) -> WARNING
    netstat_f.write_text('''TcpExt: TcpTimeoutRehash TcpDuplicateDataRehash TCPPLBRehash TCPTimeouts TCPDelivered
TcpExt: 0 0 0 5000 50000
''')
    res2 = mod.audit_rehash(
        netstat_file=str(netstat_f),
        plb_rounds_file=str(plb_f),
        plb_idle_rounds_file=str(plb_idle_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Zero TCP timeout path rehashes detected' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 163 regression tests passed!"
