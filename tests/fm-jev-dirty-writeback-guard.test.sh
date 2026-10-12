#!/usr/bin/env bash
# tests/fm-jev-dirty-writeback-guard.test.sh - Regression tests for Pattern 88 (Dirty Writeback Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-dirty-writeback-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-dirty-writeback-guard.py"

echo "Running Pattern 88 regression tests..."

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
assert 'metrics' in data
assert 'd_state_procs' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'nr_dirty_pages' in s
assert 'nr_writeback_pages' in s
assert 'dirty_mb' in s
assert 'writeback_mb' in s
assert 'saturation_pct' in s
assert 'bg_saturation_pct' in s
assert 'dirty_threshold_pages' in s
assert 'dirty_bg_threshold_pages' in s
assert 'd_state_processes' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked vmstat and procfs
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-dirty-writeback-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_vmstat = os.path.join(tmp_dir, 'vmstat')
    mock_proc = os.path.join(tmp_dir, 'proc')
    os.makedirs(mock_proc, exist_ok=True)

    # Case 1: Healthy normal levels
    with open(mock_vmstat, 'w') as f:
        f.write('''nr_dirty 1000
nr_writeback 50
nr_dirty_threshold 100000
nr_dirty_background_threshold 50000
''')

    res = mod.audit_dirty_writeback(
        vmstat_path=mock_vmstat,
        proc_dir=mock_proc,
        warn_sat_pct=70.0,
        crit_sat_pct=90.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['nr_dirty_pages'] == 1000
    assert s['nr_writeback_pages'] == 50
    assert s['saturation_pct'] == 1.0
    assert s['bg_saturation_pct'] == 2.0
    assert s['d_state_processes'] == 0

    # Case 2: Warning on elevated dirty saturation (e.g. 75,000 / 100,000 = 75%)
    with open(mock_vmstat, 'w') as f:
        f.write('''nr_dirty 75000
nr_writeback 1000
nr_dirty_threshold 100000
nr_dirty_background_threshold 50000
''')

    res_warn = mod.audit_dirty_writeback(
        vmstat_path=mock_vmstat,
        proc_dir=mock_proc,
        warn_sat_pct=70.0,
        crit_sat_pct=90.0,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('Elevated dirty page saturation' in iss for iss in res_warn['summary']['issues'])

    # Case 3: Critical on severe dirty saturation (e.g. 95,000 / 100,000 = 95%)
    with open(mock_vmstat, 'w') as f:
        f.write('''nr_dirty 95000
nr_writeback 5000
nr_dirty_threshold 100000
nr_dirty_background_threshold 50000
''')

    res_crit = mod.audit_dirty_writeback(
        vmstat_path=mock_vmstat,
        proc_dir=mock_proc,
        warn_sat_pct=70.0,
        crit_sat_pct=90.0,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('Severe dirty page saturation' in iss for iss in res_crit['summary']['issues'])

    # Case 4: Process stuck in D (uninterruptible disk sleep) state
    p_dir = os.path.join(mock_proc, '1234')
    os.makedirs(p_dir, exist_ok=True)
    with open(os.path.join(p_dir, 'stat'), 'w') as f:
        f.write('1234 (sqlite3) D 1 1234 1234 0 -1 4194304 1000 0 0 0 10 20 0 0 20 0 1 0 100 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0')

    res_d = mod.audit_dirty_writeback(
        vmstat_path=mock_vmstat,
        proc_dir=mock_proc,
        warn_sat_pct=99.0,
        crit_sat_pct=99.0,
    )
    assert res_d['summary']['d_state_processes'] == 1
    assert res_d['d_state_procs'][0]['pid'] == 1234
    assert res_d['d_state_procs'][0]['comm'] == 'sqlite3'
    assert any('stalled in uninterruptible disk sleep' in iss for iss in res_d['summary']['issues'])

    # Case 5: Fail-open on missing vmstat
    res_missing = mod.audit_dirty_writeback(vmstat_path='/nonexistent/vmstat')
    assert res_missing['summary']['healthy'] is True
    assert res_missing['summary']['nr_dirty_pages'] == 0
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 88 tests passed!"
