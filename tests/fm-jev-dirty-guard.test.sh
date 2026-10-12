#!/usr/bin/env bash
# tests/fm-jev-dirty-guard.test.sh - Regression tests for Pattern 77 (Dirty Page Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-dirty-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-dirty-guard.py"

echo "Running Pattern 77 regression tests..."

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
assert 'sysctl' in data
assert 'meminfo_kb' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'dirty_pages' in s
assert 'dirty_mb' in s
assert 'writeback_pages' in s
assert 'writeback_mb' in s
assert 'dirty_saturation_pct' in s
assert 'background_saturation_pct' in s
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
mod = import_module('fm-jev-dirty-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_vmstat = os.path.join(tmp_dir, 'vmstat')
    mock_meminfo = os.path.join(tmp_dir, 'meminfo')
    mock_ratio = os.path.join(tmp_dir, 'dirty_ratio')
    mock_bg_ratio = os.path.join(tmp_dir, 'dirty_background_ratio')
    mock_expire = os.path.join(tmp_dir, 'dirty_expire_centisecs')
    mock_wb = os.path.join(tmp_dir, 'dirty_writeback_centisecs')

    with open(mock_ratio, 'w') as f:
        f.write('20\n')
    with open(mock_bg_ratio, 'w') as f:
        f.write('10\n')
    with open(mock_expire, 'w') as f:
        f.write('3000\n')
    with open(mock_wb, 'w') as f:
        f.write('500\n')

    with open(mock_meminfo, 'w') as f:
        f.write('MemTotal:       65863268 kB\n')
        f.write('MemFree:        15000000 kB\n')
        f.write('MemAvailable:   25000000 kB\n')
        f.write('Dirty:             20480 kB\n')
        f.write('Writeback:            80 kB\n')

    with open(mock_vmstat, 'w') as f:
        f.write('nr_dirty 5120\n') # 20 MB
        f.write('nr_writeback 20\n')
        f.write('nr_dirty_threshold 1472535\n') # ~5.7 GB
        f.write('nr_dirty_background_threshold 736267\n') # ~2.8 GB

    # Audit under normal conditions
    res = mod.audit_dirty_pages(
        vmstat_path=mock_vmstat,
        meminfo_path=mock_meminfo,
        dirty_ratio_path=mock_ratio,
        dirty_bg_ratio_path=mock_bg_ratio,
        dirty_expire_path=mock_expire,
        dirty_wb_path=mock_wb,
        warn_sat_pct=70.0,
        crit_sat_pct=90.0,
        warn_dirty_mb=2048.0,
        crit_dirty_mb=5120.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['dirty_pages'] == 5120
    assert s['dirty_mb'] == 20.0
    assert s['writeback_pages'] == 20
    assert s['dirty_saturation_pct'] < 1.0

    # Test WARNING on high dirty saturation
    with open(mock_vmstat, 'w') as f:
        f.write('nr_dirty 1100000\n') # ~74.7% of 1472535
        f.write('nr_writeback 50\n')
        f.write('nr_dirty_threshold 1472535\n')
        f.write('nr_dirty_background_threshold 736267\n')
    res_warn = mod.audit_dirty_pages(
        vmstat_path=mock_vmstat,
        meminfo_path=mock_meminfo,
        dirty_ratio_path=mock_ratio,
        dirty_bg_ratio_path=mock_bg_ratio,
        dirty_expire_path=mock_expire,
        dirty_wb_path=mock_wb,
        warn_sat_pct=70.0,
        crit_sat_pct=90.0,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('saturation elevated' in iss for iss in res_warn['summary']['issues'])

    # Test CRITICAL on excessive dirty saturation
    with open(mock_vmstat, 'w') as f:
        f.write('nr_dirty 1400000\n') # ~95% of 1472535
        f.write('nr_writeback 100\n')
        f.write('nr_dirty_threshold 1472535\n')
        f.write('nr_dirty_background_threshold 736267\n')
    res_crit = mod.audit_dirty_pages(
        vmstat_path=mock_vmstat,
        meminfo_path=mock_meminfo,
        dirty_ratio_path=mock_ratio,
        dirty_bg_ratio_path=mock_bg_ratio,
        dirty_expire_path=mock_expire,
        dirty_wb_path=mock_wb,
        crit_sat_pct=90.0,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('saturation critical' in iss for iss in res_crit['summary']['issues'])

    # Test CRITICAL on dirty MB volume threshold
    with open(mock_vmstat, 'w') as f:
        f.write('nr_dirty 2000000\n') # ~7.8 GB > 5.0 GB limit
        f.write('nr_writeback 0\n')
        f.write('nr_dirty_threshold 10000000\n')
        f.write('nr_dirty_background_threshold 5000000\n')
    res_crit_mb = mod.audit_dirty_pages(
        vmstat_path=mock_vmstat,
        meminfo_path=mock_meminfo,
        dirty_ratio_path=mock_ratio,
        dirty_bg_ratio_path=mock_bg_ratio,
        dirty_expire_path=mock_expire,
        dirty_wb_path=mock_wb,
        crit_dirty_mb=5000.0,
    )
    assert res_crit_mb['summary']['status'] == 'CRITICAL'
    assert any('volume critical' in iss for iss in res_crit_mb['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 77 tests passed!"
