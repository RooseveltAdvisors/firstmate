#!/usr/bin/env bash
# tests/fm-jev-mem-guard.test.sh - Regression tests for Pattern 46 (Jev Multi-Agent Memory RSS & Swap Thrashing Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mem-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mem-guard.py"

echo "Running Pattern 46 regression tests..."

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
assert isinstance(data['summary']['mem_total_gb'], float)
assert isinstance(data['summary']['mem_available_gb'], float)
assert isinstance(data['summary']['mem_used_pct'], float)
assert isinstance(data['summary']['swap_used_pct'], float)
assert isinstance(data['summary']['healthy'], bool)
assert data['summary']['status'] in ('HEALTHY', 'WARNING', 'CRITICAL')
for p in data['top_processes']:
    assert 'pid' in p
    assert 'comm' in p
    assert 'rss_mb' in p
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
mod = import_module('fm-jev-mem-guard')

# Verify module exports and functions
assert hasattr(mod, 'audit_memory')
assert hasattr(mod, 'read_meminfo')
assert hasattr(mod, 'get_top_rss_processes')

# Verify threshold behavior
res = mod.audit_memory(warn_mem_pct=1.0, warn_swap_pct=1.0)
assert res['summary']['healthy'] is False
assert res['summary']['status'] in ('WARNING', 'CRITICAL')
"
echo "ok - threshold logic valid"

# 7. Text output format
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

echo "ok - all Pattern 46 memory guard tests passed"
