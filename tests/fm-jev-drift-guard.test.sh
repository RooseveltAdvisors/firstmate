#!/usr/bin/env bash
# tests/fm-jev-drift-guard.test.sh - Regression tests for Pattern 50 (Jev Multi-Agent Worktree Detached HEAD & Drift Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-drift-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-drift-guard.py"

echo "Running Pattern 50 regression tests..."

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
json_out="$("$GUARD_SH" --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'worktrees' in data
assert isinstance(data['summary']['total_worktrees_audited'], int)
assert isinstance(data['summary']['detached_head_count'], int)
assert isinstance(data['summary']['healthy'], bool)
for wt in data['worktrees']:
    assert 'path' in wt
    assert 'branch' in wt
    assert 'detached_head' in wt
    assert 'dirty' in wt
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Test unit audit logic with a mock repo in temp
TEST_REPO="/tmp/test-drift-repo-$$"
mkdir -p "$TEST_REPO"
git init -b main "$TEST_REPO" >/dev/null 2>&1
git -C "$TEST_REPO" config user.email "test@test.local"
git -C "$TEST_REPO" config user.name "Test Bot"
echo "hello" > "$TEST_REPO/file.txt"
git -C "$TEST_REPO" add file.txt
git -C "$TEST_REPO" commit -m "initial commit" >/dev/null 2>&1

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-drift-guard')

res = mod.audit_git_worktree('$TEST_REPO')
assert res is not None
assert res['detached_head'] is False
assert res['branch'] == 'main'
assert res['dirty'] is False
"
rm -rf "$TEST_REPO"
echo "ok - unit audit on git repository passed"

echo "ok - all Pattern 50 drift guard tests passed"
