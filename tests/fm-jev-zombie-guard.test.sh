#!/usr/bin/env bash
# tests/fm-jev-zombie-guard.test.sh - Regression tests for Pattern 45 (Jev Multi-Agent Subprocess Zombie & Defunct PPID Leak Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-zombie-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-zombie-guard.py"

echo "Running Pattern 45 regression tests..."

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
assert 'zombies' in data
assert 'parents' in data
assert isinstance(data['summary']['total_zombies'], int)
assert isinstance(data['summary']['parents_count'], int)
assert isinstance(data['summary']['healthy'], bool)
assert data['summary']['status'] in ('HEALTHY', 'WARNING', 'CRITICAL')
"
echo "ok - json audit schema valid"

# 5. Check mode works on live system
"$GUARD_SH" --check
echo "ok - --check passes on healthy system"

# 6. Test thresholding logic in Python
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-zombie-guard')

# Verify module exports and functions
assert hasattr(mod, 'audit_zombies')
assert hasattr(mod, 'get_process_cmdline')
assert hasattr(mod, 'get_process_name')

# Call audit_zombies with high threshold
res = mod.audit_zombies(warn_threshold=1000, crit_threshold=2000)
assert res['summary']['healthy'] is True
assert res['summary']['status'] == 'HEALTHY'
"
echo "ok - threshold logic valid"

# 7. Text output format
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

echo "ok - all Pattern 45 zombie guard tests passed"
