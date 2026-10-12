#!/usr/bin/env bash
# tests/fm-jev-aio-guard.test.sh - Regression tests for Pattern 316 (AioGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-aio-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-aio-guard.py"

echo "Running Pattern 316 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on host audit
json_out="$("$GUARD_SH" --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert data['pattern'] == 316
assert data['name'] == 'aio'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_capacity_healthy'], bool)
assert isinstance(data['aio_nr'], int)
assert isinstance(data['aio_max_nr'], int)
assert isinstance(data['aio_utilization_pct'], (int, float))
assert isinstance(data['aio_headroom'], int)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-aio-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'aio-nr').write_text('1024\n')
    (d / 'aio-max-nr').write_text('65536\n')

    res = mod.evaluate_aio(fs_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_capacity_healthy'] is True
    assert res['aio_nr'] == 1024
    assert res['aio_max_nr'] == 65536
    assert res['aio_headroom'] == 64512
    assert len(res['issues']) == 0

    # Test warning for constrained max floor
    (d / 'aio-max-nr').write_text('32768\n')
    res_warn = mod.evaluate_aio(fs_dir=str(d))
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert res_warn['is_capacity_healthy'] is False
    assert any('constrained' in iss for iss in res_warn['issues'])

    # Test critical for high utilization
    (d / 'aio-nr').write_text('60000\n')
    (d / 'aio-max-nr').write_text('65536\n')
    res_crit = mod.evaluate_aio(fs_dir=str(d))
    assert res_crit['healthy'] is False
    assert res_crit['status'] == 'CRITICAL'
    assert any('critical' in iss for iss in res_crit['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 316 regression tests passed successfully."
