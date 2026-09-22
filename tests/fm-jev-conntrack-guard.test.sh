#!/usr/bin/env bash
# tests/fm-jev-conntrack-guard.test.sh - Regression tests for Pattern 90 (Conntrack Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-conntrack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-conntrack-guard.py"

echo "Running Pattern 90 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'conntrack_count' in s
assert 'conntrack_max' in s
assert 'saturation_pct' in s
assert 'available_entries' in s
assert isinstance(s['conntrack_active'], bool)
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked conntrack files
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-conntrack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_count = os.path.join(tmp_dir, 'nf_conntrack_count')
    mock_max = os.path.join(tmp_dir, 'nf_conntrack_max')

    # Case 1: Healthy (1,000 / 100,000 = 1.0% saturation)
    with open(mock_count, 'w') as f:
        f.write('1000\n')
    with open(mock_max, 'w') as f:
        f.write('100000\n')

    res = mod.audit_conntrack(
        count_path=mock_count,
        max_path=mock_max,
        warn_sat_pct=70.0,
        crit_sat_pct=85.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['conntrack_count'] == 1000
    assert s['conntrack_max'] == 100000
    assert s['saturation_pct'] == 1.0
    assert s['available_entries'] == 99000
    assert s['conntrack_active'] is True

    # Case 2: Warning on elevated saturation (75,000 / 100,000 = 75.0%)
    with open(mock_count, 'w') as f:
        f.write('75000\n')

    res_warn = mod.audit_conntrack(
        count_path=mock_count,
        max_path=mock_max,
        warn_sat_pct=70.0,
        crit_sat_pct=85.0,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('Elevated conntrack' in iss for iss in res_warn['summary']['issues'])

    # Case 3: Critical on severe saturation (90,000 / 100,000 = 90.0%)
    with open(mock_count, 'w') as f:
        f.write('90000\n')

    res_crit = mod.audit_conntrack(
        count_path=mock_count,
        max_path=mock_max,
        warn_sat_pct=70.0,
        crit_sat_pct=85.0,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('Critical conntrack' in iss for iss in res_crit['summary']['issues'])

    # Case 4: Fail-open on missing files
    res_missing = mod.audit_conntrack(
        count_path='/nonexistent/count',
        max_path='/nonexistent/max',
    )
    assert res_missing['summary']['healthy'] is True
    assert res_missing['summary']['conntrack_active'] is False
    assert res_missing['summary']['conntrack_count'] == 0
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 90 tests passed!"
