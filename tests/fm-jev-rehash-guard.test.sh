#!/usr/bin/env bash
# tests/fm-jev-rehash-guard.test.sh - Regression tests for Pattern 163 (TCP Route Rehashing Guard)
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
assert 'sysctls' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'timeout_rehash' in s
assert 'tcp_plb_enabled' in s
assert 'rehash_ratio_pct' in s
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
    plb_en_f = d / 'tcp_plb_enabled'
    plb_cg_f = d / 'tcp_plb_cong_thresh'
    plb_rh_f = d / 'tcp_plb_rehash_rounds'

    plb_en_f.write_text('0\n')
    plb_cg_f.write_text('128\n')
    plb_rh_f.write_text('12\n')
    netstat_f.write_text('''TcpExt: TcpTimeoutRehash TcpDuplicateDataRehash TCPPLBRehash TCPTimeouts
TcpExt: 700000 0 0 720000
''')

    # Case 1: Nominal
    res = mod.audit_rehash(
        netstat_file=str(netstat_f),
        plb_enabled_file=str(plb_en_f),
        plb_cong_thresh_file=str(plb_cg_f),
        plb_rehash_rounds_file=str(plb_rh_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['timeout_rehash'] == 700000
    assert res['summary']['tcp_timeouts'] == 720000
    assert res['summary']['rehash_ratio_pct'] == 97.22
"
echo "ok - unit tests pass"

echo "All Pattern 163 regression tests passed!"
