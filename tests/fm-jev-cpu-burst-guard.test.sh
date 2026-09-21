#!/usr/bin/env bash
# tests/fm-jev-cpu-burst-guard.test.sh - Regression tests for Pattern 51 (Jev CPU Saturation Burst Dampener)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-cpu-burst-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-cpu-burst-guard.py"

echo "Running Pattern 51 regression tests..."

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
assert isinstance(data['summary']['logical_cpu_cores'], int)
assert isinstance(data['summary']['load_1m'], float)
assert isinstance(data['summary']['load_per_core_1m'], float)
assert isinstance(data['summary']['recommended_concurrency'], int)
assert isinstance(data['summary']['healthy'], bool)
assert data['summary']['status'] in ('HEALTHY', 'WARNING', 'CRITICAL')
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Test thresholding logic in Python
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-cpu-burst-guard')

assert hasattr(mod, 'audit_cpu_burst')
assert hasattr(mod, 'parse_loadavg')
assert hasattr(mod, 'get_cpu_core_count')

# Test threshold behavior
res = mod.audit_cpu_burst(warn_load_per_core=0.01, crit_load_per_core=0.02)
assert res['summary']['healthy'] is False
assert res['summary']['status'] in ('WARNING', 'CRITICAL')
"
echo "ok - threshold logic valid"

echo "ok - all Pattern 51 CPU burst dampener tests passed"
