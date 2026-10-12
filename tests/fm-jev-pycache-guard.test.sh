#!/usr/bin/env bash
# tests/fm-jev-pycache-guard.test.sh - Regression tests for Pattern 55 (Jev PyCache Invalidation Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pycache-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pycache-guard.py"

echo "Running Pattern 55 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on audit
json_out="$("$GUARD_SH" --paths /opt/ra/firstmate --orphan-warn 100 --orphan-crit 500 --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'roots' in data
assert isinstance(data['summary']['total_pycache_dirs'], int)
assert isinstance(data['summary']['total_orphaned_pyc_count'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --paths /opt/ra/firstmate --orphan-warn 100 --orphan-crit 500 >/dev/null
echo "ok - text mode runs cleanly"

# 6. Unit test on mock python project with orphaned pyc
TEST_DIR="/tmp/test-pycache-guard-$$"
mkdir -p "$TEST_DIR/pkg/__pycache__"

# Valid module and pyc
touch "$TEST_DIR/pkg/valid_mod.py"
touch "$TEST_DIR/pkg/__pycache__/valid_mod.cpython-311.pyc"

# Orphaned pyc (no corresponding .py)
touch "$TEST_DIR/pkg/__pycache__/deleted_mod.cpython-311.pyc"
touch "$TEST_DIR/pkg/__pycache__/legacy_mod.pyc"

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-pycache-guard')

res = mod.audit_fleet_pycache(
    search_paths=['$TEST_DIR'],
    orphan_warn=1,
    orphan_crit=5,
    max_depth=3
)
summary = res['summary']
assert summary['total_pycache_dirs'] == 1
assert summary['total_pyc_files'] == 3
assert summary['total_orphaned_pyc_count'] == 2
assert summary['status'] == 'WARNING'
assert summary['healthy'] is False

orphans = res['roots'][0]['orphans']
orphan_names = {o['pyc_name'] for o in orphans}
assert 'deleted_mod.cpython-311.pyc' in orphan_names
assert 'legacy_mod.pyc' in orphan_names
"
rm -rf "$TEST_DIR"
echo "ok - unit audit on mock pycache passed"

echo "ok - all Pattern 55 pycache guard tests passed"
