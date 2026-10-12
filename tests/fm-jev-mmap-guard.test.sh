#!/usr/bin/env bash
# tests/fm-jev-mmap-guard.test.sh - Regression tests for Pattern 62 (Jev Memory-Mapped Arena Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mmap-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mmap-guard.py"

echo "Running Pattern 62 regression tests..."

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
assert 'top_processes' in data
assert isinstance(data['summary']['max_map_count'], int)
assert isinstance(data['summary']['audited_processes'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Unit test on threshold logic
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-mmap-guard')

res = mod.audit_fleet_mmap(warn_count=1000000, warn_ratio=0.99)
assert res['summary']['healthy'] is True

# Test triggering warning with low threshold
res_warn = mod.audit_fleet_mmap(warn_count=1, warn_ratio=0.00001)
assert res_warn['summary']['healthy'] is False
assert res_warn['summary']['status'] == 'CRITICAL'
"
echo "ok - unit audit on threshold logic passed"

echo "ok - all Pattern 62 mmap guard tests passed"
