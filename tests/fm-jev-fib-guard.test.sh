#!/usr/bin/env bash
# tests/fm-jev-fib-guard.test.sh - Regression tests for Pattern 238 (FIB Trie Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-fib-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-fib-guard.py"

echo "Running Pattern 238 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['total_tables'], int)
assert isinstance(s['total_leaves'], int)
assert isinstance(s['total_prefixes'], int)
assert isinstance(s['max_depth_overall'], int)
assert isinstance(s['total_gets'], int)
assert isinstance(s['total_backtracks'], int)
assert isinstance(s['backtrack_ratio'], float)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
assert 'tables' in data
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-fib-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    fib_f = d / 'fib_triestat'

    # Mock clean trie
    fib_f.write_text(
        'Basic info: size of leaf: 48 bytes, size of tnode: 40 bytes.\n'
        'Main:\n'
        '	Aver depth:     1.00\n'
        '	Max depth:      1\n'
        '	Leaves:         2\n'
        '	Prefixes:       2\n'
        '	Internal nodes: 1\n'
        '	Pointers: 8\n'
        'Null ptrs: 6\n'
        'Total size: 1  kB\n'
        'Counters:\n'
        '---------\n'
        'gets = 10000\n'
        'backtracks = 10\n'
        'semantic match passed = 9990\n'
        'semantic match miss = 10\n'
        'null node hit= 500\n'
        'skipped node resize = 0\n'
    )

    rep = mod.audit_fib_guard(path=str(fib_f))
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['total_tables'] == 1
    assert s['total_leaves'] == 2
    assert s['total_prefixes'] == 2
    assert s['max_depth_overall'] == 1
    assert s['total_gets'] == 10000
    assert s['total_backtracks'] == 10
    assert s['backtrack_ratio'] == 0.001

    # Mock Critical condition (max_depth >= 15)
    fib_f.write_text(
        'Main:\n'
        '	Aver depth:     8.50\n'
        '	Max depth:      16\n'
        '	Leaves:         100\n'
        '	Prefixes:       100\n'
        '	Internal nodes: 50\n'
        'Total size: 10  kB\n'
        'Counters:\n'
        'gets = 10000\n'
        'backtracks = 10\n'
    )
    rep_crit = mod.audit_fib_guard(path=str(fib_f))
    assert rep_crit['summary']['status'] == 'CRITICAL'
    assert rep_crit['summary']['healthy'] is False
    assert any('Excessive FIB trie maximum depth' in iss for iss in rep_crit['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 238 tests passed successfully."
