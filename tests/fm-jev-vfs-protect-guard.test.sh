#!/usr/bin/env bash
# tests/fm-jev-vfs-protect-guard.test.sh - Regression tests for Pattern 309 (VfsProtectGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-vfs-protect-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-vfs-protect-guard.py"

echo "Running Pattern 309 regression tests..."

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
assert data['pattern'] == 309
assert data['name'] == 'vfs_protect'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['protected_symlinks'], int)
assert isinstance(data['protected_hardlinks'], int)
assert isinstance(data['protected_fifos'], int)
assert isinstance(data['protected_regular'], int)
assert isinstance(data['suid_dumpable'], int)
assert isinstance(data['mount_max'], int)
assert isinstance(data['leases_enable'], bool)
assert isinstance(data['lease_break_time_sec'], int)
assert isinstance(data['is_hardened'], bool)
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
mod = import_module('fm-jev-vfs-protect-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'protected_symlinks').write_text('1\n')
    (d / 'protected_hardlinks').write_text('1\n')
    (d / 'protected_fifos').write_text('1\n')
    (d / 'protected_regular').write_text('2\n')
    (d / 'suid_dumpable').write_text('0\n')
    (d / 'mount-max').write_text('100000\n')
    (d / 'leases-enable').write_text('1\n')
    (d / 'lease-break-time').write_text('45\n')

    res = mod.evaluate_vfs_protect(fs_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_hardened'] is True
    assert res['protected_symlinks'] == 1
    assert res['protected_hardlinks'] == 1
    assert res['protected_fifos'] == 1
    assert res['protected_regular'] == 2
    assert res['mount_max'] == 100000
    assert len(res['issues']) == 0

    # Test warnings for unhardened parameters
    (d / 'protected_symlinks').write_text('0\n')
    (d / 'protected_hardlinks').write_text('0\n')
    (d / 'protected_fifos').write_text('0\n')
    (d / 'protected_regular').write_text('0\n')
    (d / 'mount-max').write_text('500\n')

    res_warn = mod.evaluate_vfs_protect(fs_dir=str(d))
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert res_warn['is_hardened'] is False
    assert any('symlink protection' in iss for iss in res_warn['issues'])
    assert any('hardlink protection' in iss for iss in res_warn['issues'])
    assert any('FIFO protection' in iss for iss in res_warn['issues'])
    assert any('regular file protection' in iss for iss in res_warn['issues'])
    assert any('mount table maximum' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 309 regression tests passed successfully."
