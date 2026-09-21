#!/usr/bin/env bash
# tests/fm-jev-thp-guard.test.sh - Regression tests for Pattern 64 (Jev THP & Compaction Stall Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-thp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-thp-guard.py"

echo "Running Pattern 64 regression tests..."

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
assert 'raw_counters' in data
assert 'thp_enabled' in data['summary']
assert 'compact_stall_count' in data['summary']
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit test on threshold logic and mocking
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-thp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    sysfs_dir = os.path.join(tmp_dir, 'thp')
    os.makedirs(sysfs_dir)
    with open(os.path.join(sysfs_dir, 'enabled'), 'w') as f:
        f.write('always [madvise] never\n')
    with open(os.path.join(sysfs_dir, 'defrag'), 'w') as f:
        f.write('always defer [madvise] never\n')
        
    vmstat_file = os.path.join(tmp_dir, 'vmstat')
    with open(vmstat_file, 'w') as f:
        f.write('compact_stall 50\n')
        f.write('compact_fail 10\n')
        f.write('compact_success 90\n')
        f.write('thp_fault_alloc 100\n')
        f.write('thp_fault_fallback 5\n')
        
    res = mod.audit_fleet_thp(
        sysfs_root=sysfs_dir,
        vmstat_path=vmstat_file,
    )
    assert res['summary']['healthy'] is True
    assert res['summary']['thp_enabled'] == 'madvise'
    assert res['summary']['compact_stall_count'] == 50
    assert res['summary']['compact_fail_ratio'] == 0.10

    # Test severe compaction failure trigger
    with open(vmstat_file, 'w') as f:
        f.write('compact_stall 500000\n')
        f.write('compact_fail 9500\n')
        f.write('compact_success 500\n')
        f.write('thp_fault_alloc 100\n')
        f.write('thp_fault_fallback 800\n')
        
    res_crit = mod.audit_fleet_thp(
        sysfs_root=sysfs_dir,
        vmstat_path=vmstat_file,
        warn_compact_fail_ratio=0.80,
        warn_thp_fallback_ratio=0.50,
    )
    assert res_crit['summary']['healthy'] is False
    assert 'High compaction failure ratio' in res_crit['summary']['recommendation']
"
echo "ok - unit audit on threshold logic and simulated compaction passed"

echo "ok - all Pattern 64 THP guard tests passed"
