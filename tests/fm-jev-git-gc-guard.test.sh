#!/usr/bin/env bash
# tests/fm-jev-git-gc-guard.test.sh - Regression tests for Pattern 53 (Jev Git Object Hygiene Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-git-gc-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-git-gc-guard.py"

echo "Running Pattern 53 regression tests..."

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
json_out="$("$GUARD_SH" --paths /opt/ra/firstmate --loose-warn 10000 --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'repositories' in data
assert isinstance(data['summary']['unique_repos_found'], int)
assert isinstance(data['summary']['total_loose_objects'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --paths /opt/ra/firstmate --loose-warn 10000 >/dev/null
echo "ok - text mode runs cleanly"

# 6. Unit test on mock git repository with loose objects
TEST_DIR="/tmp/test-git-gc-guard-$$"
mkdir -p "$TEST_DIR/mock_repo/.git/objects/4b"
mkdir -p "$TEST_DIR/mock_repo/.git/objects/pack"
# Create mock loose objects
echo "blob 1" > "$TEST_DIR/mock_repo/.git/objects/4b/825dc642cb6eb9a060e54bf8d69288fbee4904"
echo "blob 2" > "$TEST_DIR/mock_repo/.git/objects/4b/11111111111111111111111111111111111111"
# Create mock packfile
echo "pack data" > "$TEST_DIR/mock_repo/.git/objects/pack/pack-1234.pack"
echo "idx data" > "$TEST_DIR/mock_repo/.git/objects/pack/pack-1234.idx"

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-git-gc-guard')

res = mod.audit_fleet_git_objects(
    search_paths=['$TEST_DIR'],
    loose_warn=5,
    loose_crit=10,
    pack_warn=5,
    max_depth=2
)
summary = res['summary']
assert summary['unique_repos_found'] == 1
assert summary['total_loose_objects'] == 2
assert summary['total_pack_files'] == 1
assert summary['healthy'] is True

# Test warning threshold
res_warn = mod.audit_fleet_git_objects(
    search_paths=['$TEST_DIR'],
    loose_warn=1,
    loose_crit=10,
    pack_warn=5,
    max_depth=2
)
assert res_warn['summary']['warning_repos_count'] == 1
assert res_warn['summary']['healthy'] is False
assert res_warn['repositories'][0]['status'] == 'WARNING'
"
rm -rf "$TEST_DIR"
echo "ok - unit audit on mock git repository passed"

echo "ok - all Pattern 53 git gc guard tests passed"
