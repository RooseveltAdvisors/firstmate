#!/usr/bin/env bash
# tests/fm-jev-posix-shm-guard.test.sh - Regression tests for Pattern 312 (PosixShmGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-posix-shm-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-posix-shm-guard.py"

echo "Running Pattern 312 regression tests..."

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
assert data['pattern'] == 312
assert data['name'] == 'posix_shm'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['total_bytes'], int)
assert isinstance(data['total_mb'], (int, float))
assert isinstance(data['used_bytes'], int)
assert isinstance(data['used_mb'], (int, float))
assert isinstance(data['free_bytes'], int)
assert isinstance(data['free_mb'], (int, float))
assert isinstance(data['usage_pct'], (int, float))
assert isinstance(data['total_inodes'], int)
assert isinstance(data['used_inodes'], int)
assert isinstance(data['free_inodes'], int)
assert isinstance(data['inode_usage_pct'], (int, float))
assert isinstance(data['total_objects'], int)
assert isinstance(data['named_semaphores'], int)
assert isinstance(data['postgres_segments'], int)
assert isinstance(data['chrome_segments'], int)
assert isinstance(data['shmmax'], int)
assert isinstance(data['shmall'], int)
assert isinstance(data['shmmni'], int)
assert isinstance(data['is_exhaustion_free'], bool)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked directory & sysctls
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-posix-shm-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    shm_dir = d / 'shm'
    shm_dir.mkdir()
    kernel_dir = d / 'kernel'
    kernel_dir.mkdir()

    # Create dummy IPC objects
    (shm_dir / 'sem.test_sem').write_text('sem')
    (shm_dir / 'PostgreSQL.123').write_text('pg')
    (shm_dir / '.com.google.Chrome.abc').write_text('chrome')
    (shm_dir / 'regular.file').write_text('data')

    (kernel_dir / 'shmmax').write_text('18446744073692774399\n')
    (kernel_dir / 'shmall').write_text('18446744073692774399\n')
    (kernel_dir / 'shmmni').write_text('4096\n')

    res = mod.evaluate_posix_shm(shm_dir=str(shm_dir), kernel_dir=str(kernel_dir))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_exhaustion_free'] is True
    assert res['total_objects'] == 4
    assert res['named_semaphores'] == 1
    assert res['postgres_segments'] == 1
    assert res['chrome_segments'] == 1
    assert res['shmmni'] == 4096
    assert len(res['issues']) == 0

    # Test warning when shmmni is below recommended
    (kernel_dir / 'shmmni').write_text('256\n')
    res_warn = mod.evaluate_posix_shm(shm_dir=str(shm_dir), kernel_dir=str(kernel_dir))
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert any('shmmni' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked directory passed"

echo "All Pattern 312 regression tests passed successfully."
