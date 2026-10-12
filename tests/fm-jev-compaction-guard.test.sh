#!/usr/bin/env bash
# tests/fm-jev-compaction-guard.test.sh - Regression tests for Pattern 317 (CompactionGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-compaction-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-compaction-guard.py"

echo "Running Pattern 317 regression tests..."

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
assert data['pattern'] == 317
assert data['name'] == 'compaction'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_compaction_healthy'], bool)
assert isinstance(data['extfrag_threshold'], int)
assert isinstance(data['compaction_proactiveness'], int)
assert isinstance(data['thp_defrag'], str)
assert isinstance(data['compact_stall'], int)
assert isinstance(data['compact_fail'], int)
assert isinstance(data['compact_success'], int)
assert isinstance(data['compact_fail_pct'], (int, float))
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
mod = import_module('fm-jev-compaction-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    vm_dir = d / 'vm'
    vm_dir.mkdir()
    (vm_dir / 'extfrag_threshold').write_text('500\n')
    (vm_dir / 'compaction_proactiveness').write_text('20\n')

    thp_file = d / 'defrag'
    thp_file.write_text('always defer [defer+madvise] madvise never\n')

    vmstat_file = d / 'vmstat'
    vmstat_file.write_text(
        'compact_stall 100\n'
        'compact_fail 20\n'
        'compact_success 80\n'
        'compact_daemon_wake 500\n'
        'compact_migrate_scanned 1000\n'
        'compact_free_scanned 2000\n'
        'compact_isolated 500\n'
    )

    res = mod.evaluate_compaction(
        proc_sys_vm_dir=str(vm_dir),
        vmstat_file=str(vmstat_file),
        thp_defrag_file=str(thp_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_compaction_healthy'] is True
    assert res['extfrag_threshold'] == 500
    assert res['compaction_proactiveness'] == 20
    assert res['thp_defrag'] == 'defer+madvise'
    assert res['compact_stall'] == 100
    assert res['compact_fail'] == 20
    assert res['compact_success'] == 80
    assert res['compact_fail_pct'] == 20.0
    assert len(res['issues']) == 0

    # Test warning on thp_defrag == 'always'
    thp_file.write_text('[always] defer defer+madvise madvise never\n')
    res_warn = mod.evaluate_compaction(
        proc_sys_vm_dir=str(vm_dir),
        vmstat_file=str(vmstat_file),
        thp_defrag_file=str(thp_file),
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert res_warn['is_compaction_healthy'] is False
    assert any('always' in iss for iss in res_warn['issues'])

    # Test critical on compaction_proactiveness >= 95
    thp_file.write_text('always defer [madvise] never\n')
    (vm_dir / 'compaction_proactiveness').write_text('95\n')
    res_crit = mod.evaluate_compaction(
        proc_sys_vm_dir=str(vm_dir),
        vmstat_file=str(vmstat_file),
        thp_defrag_file=str(thp_file),
    )
    assert res_crit['healthy'] is False
    assert res_crit['status'] == 'CRITICAL'
    assert any('critical' in iss for iss in res_crit['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 317 regression tests passed successfully."
