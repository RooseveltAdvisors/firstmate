#!/usr/bin/env bash
# tests/fm-jev-inode-guard.test.sh - Regression tests for Pattern 48 (Jev Multi-Agent Inode Exhaustion Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-inode-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-inode-guard.py"

echo "Running Pattern 48 regression tests..."

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
assert 'mounts' in data
assert isinstance(data['summary']['monitored_mounts'], int)
assert isinstance(data['summary']['max_used_pct'], float)
assert isinstance(data['summary']['healthy'], bool)
assert data['summary']['status'] in ('HEALTHY', 'WARNING', 'CRITICAL')
for m in data['mounts']:
    assert 'path' in m
    assert 'total_inodes' in m
    assert 'free_inodes' in m
    assert 'used_pct' in m
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --check
echo "ok - --check passes on live host"

# 6. Test thresholding logic in Python
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-inode-guard')

assert hasattr(mod, 'audit_inodes')
assert hasattr(mod, 'audit_path_inodes')

# Test threshold behavior
res = mod.audit_inodes(warn_pct=0.1, crit_pct=0.2)
assert res['summary']['healthy'] is False
assert res['summary']['status'] in ('WARNING', 'CRITICAL')
"
echo "ok - threshold logic valid"

# 7. Text output format
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

echo "ok - all Pattern 48 inode guard tests passed"
