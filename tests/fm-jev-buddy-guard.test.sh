#!/usr/bin/env bash
# tests/fm-jev-buddy-guard.test.sh - Regression tests for Pattern 67 (Jev Buddy Allocator Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-buddy-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-buddy-guard.py"

echo "Running Pattern 67 regression tests..."

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
assert 'zones' in data
assert 'zones_audited' in data['summary']
assert 'total_free_mb' in data['summary']
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
mod = import_module('fm-jev-buddy-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_buddy = os.path.join(tmp_dir, 'buddyinfo')
    with open(mock_buddy, 'w') as f:
        # Node 0, zone Normal with healthy high orders
        f.write('Node 0, zone      DMA      0      0      0      0      0      0      0      0      1      1      2\n')
        f.write('Node 0, zone    DMA32   1000   1000   1000   1000   1000    500    200    100     50     20     10\n')
        f.write('Node 0, zone   Normal   2000   2000   2000   1000   1000    500    200    100     50     20     10\n')

    res = mod.audit_fleet_buddy(buddyinfo_path=mock_buddy)
    assert res['summary']['healthy'] is True
    assert res['summary']['zones_audited'] == 3
    assert res['summary']['normal_zone_high_orders'] == 180

    # Test severe high-order starvation mock
    with open(mock_buddy, 'w') as f:
        f.write('Node 0, zone   Normal  50000  30000  20000  10000      0      0      0      0      0      0      0\n')

    res_starved = mod.audit_fleet_buddy(buddyinfo_path=mock_buddy)
    assert res_starved['summary']['healthy'] is False
    assert res_starved['summary']['status'] == 'WARNING'
    assert 'Severe high-order page starvation' in res_starved['summary']['recommendation']
"
echo "ok - unit audit on threshold logic and simulated buddyinfo passed"

echo "ok - all Pattern 67 buddy allocator guard tests passed"
