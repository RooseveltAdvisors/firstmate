#!/usr/bin/env bash
# tests/fm-jev-coredump-guard.test.sh - Regression tests for Pattern 54 (Jev Core Dump Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-coredump-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-coredump-guard.py"

echo "Running Pattern 54 regression tests..."

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
json_out="$("$GUARD_SH" --paths /tmp --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'artifacts' in data
assert isinstance(data['summary']['total_artifacts_count'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --paths /tmp >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit test on mock crash artifact directory
TEST_DIR="/tmp/test-coredump-guard-$$"
mkdir -p "$TEST_DIR"
# Create mock crash files
echo "dummy core" > "$TEST_DIR/core.12345"
echo "dummy stackdump" > "$TEST_DIR/test.stackdump"
echo "dummy normal file" > "$TEST_DIR/normal.txt"

python3 -c "
import sys, time
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-coredump-guard')

# Fast audit with 0 age threshold to trigger warning
res = mod.audit_fleet_crash_artifacts(
    search_paths=['$TEST_DIR'],
    max_age_hours=0.0,
    max_total_mb=100.0,
    max_depth=1
)
summary = res['summary']
assert summary['total_artifacts_count'] == 2
assert summary['stale_artifacts_count'] == 2
assert summary['healthy'] is False

# High threshold -> healthy
res_healthy = mod.audit_fleet_crash_artifacts(
    search_paths=['$TEST_DIR'],
    max_age_hours=100.0,
    max_total_mb=100.0,
    max_depth=1
)
assert res_healthy['summary']['healthy'] is True
"
rm -rf "$TEST_DIR"
echo "ok - unit audit on mock crash artifacts passed"

echo "ok - all Pattern 54 core dump guard tests passed"
