#!/usr/bin/env bash
# tests/fm-jev-pty-guard.test.sh - Regression tests for Pattern 47 (Jev Multi-Agent PTY/TTY Allocation Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pty-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pty-guard.py"

echo "Running Pattern 47 regression tests..."

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
assert isinstance(data['summary']['allocated_pty'], int)
assert isinstance(data['summary']['max_pty'], int)
assert isinstance(data['summary']['utilization_pct'], float)
assert isinstance(data['summary']['healthy'], bool)
assert data['summary']['status'] in ('HEALTHY', 'WARNING', 'CRITICAL')
"
echo "ok - json audit schema valid"

# 5. Check mode works on live system
"$GUARD_SH" --check
echo "ok - --check passes on live host"

# 6. Test thresholding logic in Python
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-pty-guard')

assert hasattr(mod, 'audit_pty_usage')
assert hasattr(mod, 'get_pty_limits')

# Test threshold behavior
res = mod.audit_pty_usage(warn_pct=0.1, crit_pct=0.2)
assert res['summary']['healthy'] is False
assert res['summary']['status'] in ('WARNING', 'CRITICAL')
"
echo "ok - threshold logic valid"

# 7. Text output format
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

echo "ok - all Pattern 47 PTY guard tests passed"
