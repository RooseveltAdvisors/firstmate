#!/usr/bin/env bash
# tests/fm-jev-slab-guard.test.sh - Regression tests for Pattern 89 (Slab Cache Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-slab-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-slab-guard.py"

echo "Running Pattern 89 regression tests..."

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
assert 'timestamp' in data
assert 'summary' in data
assert 'slab_memory' in data
assert 'dentry_cache' in data
assert 'inode_cache' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'slab_mb' in s
assert 'reclaimable_mb' in s
assert 'unreclaimable_mb' in s
assert 'slab_pct_of_ram' in s
assert 'unreclaim_pct_of_ram' in s
assert 'dentry_count' in s
assert 'inode_count' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs files
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-slab-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_meminfo = os.path.join(tmp_dir, 'meminfo')
    mock_dentry = os.path.join(tmp_dir, 'dentry-state')
    mock_inode = os.path.join(tmp_dir, 'inode-state')

    # Setup normal mock files: 64 GB RAM, 10 GB Slab (8 GB Reclaim, 2 GB Unreclaim)
    with open(mock_meminfo, 'w') as f:
        f.write('''MemTotal:       67108864 kB
Slab:           10485760 kB
SReclaimable:    8388608 kB
SUnreclaim:      2097152 kB
''')
    with open(mock_dentry, 'w') as f:
        f.write('1000000\t800000\t45\t0\t10000\t0\n')
    with open(mock_inode, 'w') as f:
        f.write('2000000\t500000\t0\t0\t0\t0\t0\n')

    # Case 1: Healthy
    res = mod.audit_slab(
        meminfo_path=mock_meminfo,
        dentry_state_path=mock_dentry,
        inode_state_path=mock_inode,
        warn_unreclaim_mb=4096.0,
        crit_unreclaim_mb=8192.0,
        warn_dentry_millions=5.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['unreclaimable_mb'] == 2048.0
    assert s['dentry_count'] == 1000000
    assert s['inode_count'] == 2000000

    # Case 2: Warning on elevated unreclaimable slab
    res_warn = mod.audit_slab(
        meminfo_path=mock_meminfo,
        dentry_state_path=mock_dentry,
        inode_state_path=mock_inode,
        warn_unreclaim_mb=1024.0,  # 2048 >= 1024
        crit_unreclaim_mb=8192.0,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('Elevated unreclaimable' in iss for iss in res_warn['summary']['issues'])

    # Case 3: Critical on high unreclaimable slab
    res_crit = mod.audit_slab(
        meminfo_path=mock_meminfo,
        dentry_state_path=mock_dentry,
        inode_state_path=mock_inode,
        warn_unreclaim_mb=1024.0,
        crit_unreclaim_mb=2000.0,  # 2048 >= 2000
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('Critical unreclaimable' in iss for iss in res_crit['summary']['issues'])

    # Case 4: Warning on elevated dentry cache volume
    res_dentry = mod.audit_slab(
        meminfo_path=mock_meminfo,
        dentry_state_path=mock_dentry,
        inode_state_path=mock_inode,
        warn_dentry_millions=0.5,  # 1.0M >= 0.5M
    )
    assert res_dentry['summary']['status'] == 'WARNING'
    assert any('Elevated dentry cache' in iss for iss in res_dentry['summary']['issues'])

    # Case 5: Fail-open on missing files
    res_missing = mod.audit_slab(
        meminfo_path='/nonexistent/meminfo',
        dentry_state_path='/nonexistent/dentry',
        inode_state_path='/nonexistent/inode',
    )
    assert res_missing['summary']['healthy'] is True
    assert res_missing['summary']['slab_mb'] == 0.0
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 89 tests passed!"
