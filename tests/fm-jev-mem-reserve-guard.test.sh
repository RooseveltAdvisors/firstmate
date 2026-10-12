#!/usr/bin/env bash
# tests/fm-jev-mem-reserve-guard.test.sh - Regression tests for Pattern 311 (MemReserveGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mem-reserve-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mem-reserve-guard.py"

echo "Running Pattern 311 regression tests..."

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
assert data['pattern'] == 311
assert data['name'] == 'mem_reserve'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['admin_reserve_kbytes'], int)
assert isinstance(data['admin_reserve_mb'], (int, float))
assert isinstance(data['user_reserve_kbytes'], int)
assert isinstance(data['user_reserve_mb'], (int, float))
assert isinstance(data['min_free_kbytes'], int)
assert isinstance(data['min_free_mb'], (int, float))
assert isinstance(data['min_slab_ratio'], int)
assert isinstance(data['lowmem_reserve_ratios'], list)
assert isinstance(data['is_adequately_reserved'], bool)
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
mod = import_module('fm-jev-mem-reserve-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'admin_reserve_kbytes').write_text('8192\n')
    (d / 'user_reserve_kbytes').write_text('131072\n')
    (d / 'min_slab_ratio').write_text('5\n')
    (d / 'min_free_kbytes').write_text('67584\n')
    (d / 'lowmem_reserve_ratio').write_text('256 256 32 0 0\n')

    res = mod.evaluate_mem_reserve(vm_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_adequately_reserved'] is True
    assert res['admin_reserve_kbytes'] == 8192
    assert res['admin_reserve_mb'] == 8.0
    assert res['user_reserve_kbytes'] == 131072
    assert res['user_reserve_mb'] == 128.0
    assert res['lowmem_reserve_ratios'] == [256, 256, 32, 0, 0]
    assert len(res['issues']) == 0

    # Test warnings for undersized headroom
    (d / 'admin_reserve_kbytes').write_text('2048\n')
    (d / 'user_reserve_kbytes').write_text('16384\n')

    res_warn = mod.evaluate_mem_reserve(vm_dir=str(d))
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert res_warn['is_adequately_reserved'] is False
    assert any('admin_reserve_kbytes' in iss for iss in res_warn['issues'])
    assert any('user_reserve_kbytes' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 311 regression tests passed successfully."
