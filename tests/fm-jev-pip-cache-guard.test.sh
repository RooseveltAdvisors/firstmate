#!/usr/bin/env bash
# tests/fm-jev-pip-cache-guard.test.sh - Regression tests for Pattern 59 (Jev Pip Cache Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pip-cache-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pip-cache-guard.py"

echo "Running Pattern 59 regression tests..."

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
json_out="$("$GUARD_SH" --max-total-gb 100 --max-single-gb 100 --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'caches' in data
assert isinstance(data['summary']['total_size_gb'], float)
assert isinstance(data['summary']['total_wheels'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --max-total-gb 100 --max-single-gb 100 >/dev/null
echo "ok - text mode runs cleanly"

# 6. Unit test on mock cache directory
TEST_DIR="/tmp/test-pip-cache-guard-$$"
mkdir -p "$TEST_DIR/mock_cache/wheels"
touch "$TEST_DIR/mock_cache/wheels/pkg1-1.0-py3-none-any.whl"
touch "$TEST_DIR/mock_cache/wheels/pkg2-2.0-py3-none-any.whl"
touch "$TEST_DIR/mock_cache/src.tar.gz"

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-pip-cache-guard')

wheels, tarballs = mod.count_cache_wheels('$TEST_DIR/mock_cache')
assert wheels == 2
assert tarballs == 1

res = mod.audit_fleet_pip_caches(
    cache_paths=['$TEST_DIR/mock_cache'],
    max_total_gb=10.0,
    max_single_gb=5.0
)
assert res['summary']['total_wheels'] == 2
assert res['summary']['total_tarballs'] == 1
assert res['summary']['healthy'] is True
"
rm -rf "$TEST_DIR"
echo "ok - unit audit on mock package cache passed"

echo "ok - all Pattern 59 pip cache guard tests passed"
