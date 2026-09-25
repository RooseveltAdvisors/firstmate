#!/usr/bin/env bash
# tests/fm-jev-aslr-guard.test.sh - Regression tests for Pattern 315 (AslrGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-aslr-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-aslr-guard.py"

echo "Running Pattern 315 regression tests..."

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
assert data['pattern'] == 315
assert data['name'] == 'aslr'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_hardened'], bool)
assert isinstance(data['randomize_va_space'], int)
assert isinstance(data['aslr_mode'], str)
assert isinstance(data['mmap_min_addr'], int)
assert isinstance(data['unprivileged_userfaultfd'], bool)
assert isinstance(data['legacy_va_layout'], bool)
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
mod = import_module('fm-jev-aslr-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    k_dir = d / 'kernel'
    vm_dir = d / 'vm'
    k_dir.mkdir()
    vm_dir.mkdir()

    (k_dir / 'randomize_va_space').write_text('2\n')
    (vm_dir / 'mmap_min_addr').write_text('65536\n')
    (vm_dir / 'unprivileged_userfaultfd').write_text('0\n')
    (vm_dir / 'legacy_va_layout').write_text('0\n')

    res = mod.evaluate_aslr(kernel_dir=str(k_dir), vm_dir=str(vm_dir))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_hardened'] is True
    assert res['randomize_va_space'] == 2
    assert res['aslr_mode'] == 'full'
    assert res['mmap_min_addr'] == 65536
    assert res['unprivileged_userfaultfd'] is False
    assert res['legacy_va_layout'] is False
    assert len(res['issues']) == 0

    # Test critical for disabled ASLR
    (k_dir / 'randomize_va_space').write_text('0\n')
    res_crit = mod.evaluate_aslr(kernel_dir=str(k_dir), vm_dir=str(vm_dir))
    assert res_crit['healthy'] is False
    assert res_crit['status'] == 'CRITICAL'
    assert res_crit['is_hardened'] is False
    assert any('completely disabled' in iss for iss in res_crit['issues'])

    # Test warning for enabled unprivileged userfaultfd
    (k_dir / 'randomize_va_space').write_text('2\n')
    (vm_dir / 'unprivileged_userfaultfd').write_text('1\n')
    res_warn = mod.evaluate_aslr(kernel_dir=str(k_dir), vm_dir=str(vm_dir))
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert res_warn['is_hardened'] is False
    assert any('userfaultfd is enabled' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 315 regression tests passed successfully."
