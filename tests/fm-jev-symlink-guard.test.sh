#!/usr/bin/env bash
# tests/fm-jev-symlink-guard.test.sh - Regression tests for Pattern 52 (Jev Broken Symlink & Worktree Link Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-symlink-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-symlink-guard.py"

echo "Running Pattern 52 regression tests..."

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
json_out="$("$GUARD_SH" --paths /opt/ra/firstmate/bin --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'broken_links' in data
assert isinstance(data['summary']['broken_links_count'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --paths /opt/ra/firstmate/bin >/dev/null
echo "ok - text mode runs cleanly"

# 6. Test unit audit logic with a mock broken symlink in temp
TEST_DIR="/tmp/test-symlink-guard-$$"
mkdir -p "$TEST_DIR"
# Create a broken symlink pointing to non-existent target
ln -s "$TEST_DIR/nonexistent_file" "$TEST_DIR/broken_link"
# Create a valid symlink pointing to real file
touch "$TEST_DIR/real_file"
ln -s "$TEST_DIR/real_file" "$TEST_DIR/valid_link"

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-symlink-guard')

broken = mod.audit_path_symlinks('$TEST_DIR')
assert len(broken) == 1
assert broken[0]['path'] == '$TEST_DIR/broken_link'
assert broken[0]['type'] == 'broken_symlink'
"
rm -rf "$TEST_DIR"
echo "ok - unit audit on broken symlinks passed"

echo "ok - all Pattern 52 symlink guard tests passed"
