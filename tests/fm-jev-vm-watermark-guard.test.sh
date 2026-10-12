#!/usr/bin/env bash
# tests/fm-jev-vm-watermark-guard.test.sh - Regression tests for Pattern 201 (Kernel VM Watermarks Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-vm-watermark-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-vm-watermark-guard.py"

echo "Running Pattern 201 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['min_free_kbytes'], int)
assert isinstance(s['watermark_scale_factor'], int)
assert isinstance(s['direct_reclaim_ratio_pct'], float)
assert isinstance(s['total_alloc_stalls'], int)
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-vm-watermark-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sys_dir = d / 'vm'
    sys_dir.mkdir()
    vmstat_f = d / 'vmstat'

    # 1. Healthy baseline
    (sys_dir / 'min_free_kbytes').write_text('67584\n')
    (sys_dir / 'watermark_scale_factor').write_text('10\n')
    (sys_dir / 'watermark_boost_factor').write_text('15000\n')
    (sys_dir / 'vfs_cache_pressure').write_text('100\n')
    (sys_dir / 'swappiness').write_text('10\n')

    vmstat_f.write_text(
        'pgscan_kswapd 1000000\n'
        'pgscan_direct 100000\n'
        'pgscan_direct_throttle 0\n'
        'allocstall_normal 500\n'
        'allocstall_movable 1000\n'
        'pageoutrun 2000\n'
    )

    rep = mod.audit_vm_watermarks(
        proc_sys_vm=str(sys_dir),
        proc_vmstat=str(vmstat_f),
        warn_direct_reclaim_pct=35.0
    )
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['direct_reclaim_ratio_pct'] == round(100000 / 1100000 * 100.0, 2)
    assert s['total_alloc_stalls'] == 1500

    # 2. Elevated direct reclaim -> WARNING
    vmstat_f.write_text(
        'pgscan_kswapd 100000\n'
        'pgscan_direct 100000\n'
        'pgscan_direct_throttle 0\n'
        'allocstall_normal 500\n'
        'pageoutrun 2000\n'
    )
    rep2 = mod.audit_vm_watermarks(
        proc_sys_vm=str(sys_dir),
        proc_vmstat=str(vmstat_f),
        warn_direct_reclaim_pct=35.0
    )
    assert rep2['summary']['status'] == 'WARNING'
    assert rep2['summary']['healthy'] is False

    # 3. Direct reclaim throttling -> CRITICAL
    vmstat_f.write_text(
        'pgscan_kswapd 1000000\n'
        'pgscan_direct 100000\n'
        'pgscan_direct_throttle 5\n'
        'allocstall_normal 500\n'
        'pageoutrun 2000\n'
    )
    rep3 = mod.audit_vm_watermarks(
        proc_sys_vm=str(sys_dir),
        proc_vmstat=str(vmstat_f),
        warn_direct_reclaim_pct=35.0
    )
    assert rep3['summary']['status'] == 'CRITICAL'
    assert rep3['summary']['healthy'] is False
"
echo "ok - mocked unit tests pass"

echo "All Pattern 201 tests passed successfully."
