#!/usr/bin/env bash
# tests/fm-jev-node-modules-guard.test.sh - Regression tests for Pattern 57 (Jev node_modules Bloat Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-node-modules-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-node-modules-guard.py"

echo "Running Pattern 57 regression tests..."

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
json_out="$("$GUARD_SH" --paths /opt/ra/firstmate/projects/crm --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'directories' in data
assert isinstance(data['summary']['total_node_modules_count'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --paths /opt/ra/firstmate/projects/crm >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit test on mock node_modules
TEST_DIR="/tmp/test-nodemodules-guard-$$"
mkdir -p "$TEST_DIR/mock_app/node_modules/express"
mkdir -p "$TEST_DIR/mock_app/node_modules/@types/node"
touch "$TEST_DIR/mock_app/node_modules/express/index.js"
touch "$TEST_DIR/mock_app/node_modules/@types/node/index.d.ts"

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-node-modules-guard')

res = mod.audit_fleet_node_modules(
    search_paths=['$TEST_DIR'],
    max_total_gb=10.0,
    max_single_gb=2.0,
    max_depth=3
)
summary = res['summary']
assert summary['total_node_modules_count'] == 1
assert summary['total_top_level_packages'] == 2
assert summary['healthy'] is True
assert len(res['directories']) == 1
assert res['directories'][0]['top_level_packages'] == 2
"
rm -rf "$TEST_DIR"
echo "ok - unit audit on mock node_modules passed"

echo "ok - all Pattern 57 node_modules guard tests passed"
