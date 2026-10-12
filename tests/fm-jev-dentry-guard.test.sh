#!/usr/bin/env bash
# tests/fm-jev-dentry-guard.test.sh - Regression tests for Pattern 71 (Dentry & Inode Slab Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-dentry-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-dentry-guard.py"

echo "Running Pattern 71 regression tests..."

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
json_out="$("$GUARD_SH" --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'dentry_state' in data
assert 'inode_state' in data
assert 'meminfo_slab' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'nr_dentries' in s
assert 'nr_unused_dentries' in s
assert 'slab_reclaimable_gb' in s
assert 'vfs_cache_pressure' in s
"
echo "ok - json audit schema valid"

# 5. Check mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit test on threshold logic and mocking
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-dentry-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_dentry = os.path.join(tmp_dir, 'dentry-state')
    mock_inode = os.path.join(tmp_dir, 'inode-state')
    mock_meminfo = os.path.join(tmp_dir, 'meminfo')
    mock_pressure = os.path.join(tmp_dir, 'vfs_cache_pressure')

    with open(mock_pressure, 'w') as f:
        f.write('100\n')

    # Test 1: Healthy scenario (low dentries, low reclaimable slab)
    with open(mock_dentry, 'w') as f:
        f.write('500000 400000 45 0 10000 0\n')
    with open(mock_inode, 'w') as f:
        f.write('600000 100000 0 0 0 0 0\n')
    with open(mock_meminfo, 'w') as f:
        f.write('Slab:            2097152 kB\nSReclaimable:    1048576 kB\nSUnreclaim:      1048576 kB\n')

    res = mod.audit_dentry_slab(
        dentry_path=mock_dentry,
        inode_path=mock_inode,
        meminfo_path=mock_meminfo,
        vfs_cache_pressure_path=mock_pressure,
    )
    assert res['summary']['healthy'] is True
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['nr_dentries'] == 500000
    assert res['summary']['slab_reclaimable_gb'] == 1.0

    # Test 2: Warning scenario (elevated slab reclaimable)
    with open(mock_meminfo, 'w') as f:
        f.write('Slab:           20971520 kB\nSReclaimable:   17825792 kB\nSUnreclaim:      3145728 kB\n')

    res_warn = mod.audit_dentry_slab(
        dentry_path=mock_dentry,
        inode_path=mock_inode,
        meminfo_path=mock_meminfo,
        vfs_cache_pressure_path=mock_pressure,
        warn_reclaimable_gb=15.0,
    )
    assert res_warn['summary']['healthy'] is False
    assert res_warn['summary']['status'] == 'WARNING'
    assert 'Elevated kernel slab cache' in res_warn['summary']['recommendation']

    # Test 3: Critical scenario (severe slab bloat > 25 GB)
    with open(mock_meminfo, 'w') as f:
        f.write('Slab:           35000000 kB\nSReclaimable:   30000000 kB\nSUnreclaim:      5000000 kB\n')

    res_crit = mod.audit_dentry_slab(
        dentry_path=mock_dentry,
        inode_path=mock_inode,
        meminfo_path=mock_meminfo,
        vfs_cache_pressure_path=mock_pressure,
    )
    assert res_crit['summary']['healthy'] is False
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert 'Severe kernel slab bloat' in res_crit['summary']['recommendation']
"
echo "ok - unit tests on threshold logic and simulated dentry/meminfo passed"

echo "ok - all Pattern 71 dentry & inode slab guard tests passed"
