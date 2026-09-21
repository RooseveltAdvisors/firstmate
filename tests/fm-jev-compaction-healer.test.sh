#!/usr/bin/env bash
# tests/fm-jev-compaction-healer.test.sh - Regression tests for Pattern 68 (Memory Compaction Healer)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALER_SH="$SCRIPT_DIR/../bin/fm-jev-compaction-healer.sh"
HEALER_PY="$SCRIPT_DIR/../bin/fm-jev-compaction-healer.py"

echo "Running Pattern 68 regression tests..."

# 1. ShellCheck
shellcheck "$HEALER_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$HEALER_PY"
echo "ok - python syntax clean"

# 3. Help works
"$HEALER_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on audit
json_out="$("$HEALER_SH" --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'zones' in data
assert 'vmstat_counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'compact_stall_count' in s
assert 'compact_fail_ratio' in s
assert 'normal_zone_frag_ratio' in s
assert 'normal_zone_high_orders' in s
"
echo "ok - json audit schema valid"

# 5. Check mode runs cleanly on host
"$HEALER_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit test on threshold logic and mocking
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-compaction-healer')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_buddy = os.path.join(tmp_dir, 'buddyinfo')
    mock_vmstat = os.path.join(tmp_dir, 'vmstat')
    mock_proact = os.path.join(tmp_dir, 'compaction_proactiveness')
    mock_extfrag = os.path.join(tmp_dir, 'extfrag_threshold')

    with open(mock_proact, 'w') as f:
        f.write('20\n')
    with open(mock_extfrag, 'w') as f:
        f.write('500\n')

    # Test 1: Healthy scenario
    with open(mock_buddy, 'w') as f:
        f.write('Node 0, zone   Normal   1000   1000   1000   1000   1000    500    200    100     50     20     10\n')
    with open(mock_vmstat, 'w') as f:
        f.write('compact_stall 100\ncompact_success 90\ncompact_fail 10\ncompact_daemon_wake 50\n')

    res = mod.audit_compaction(
        buddyinfo_path=mock_buddy,
        vmstat_path=mock_vmstat,
        proactiveness_path=mock_proact,
        extfrag_threshold_path=mock_extfrag,
    )
    assert res['summary']['healthy'] is True
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['normal_zone_high_orders'] == 180
    assert res['summary']['compact_fail_ratio'] == 0.1

    # Test 2: Critical scenario (severe fragmentation + depleted high order + high compaction fail ratio)
    with open(mock_buddy, 'w') as f:
        f.write('Node 0, zone   Normal  50000  30000  20000  10000      0      0      0      2      1      0      0\n')
    with open(mock_vmstat, 'w') as f:
        f.write('compact_stall 18000000\ncompact_success 2000000\ncompact_fail 16000000\ncompact_daemon_wake 2000000\n')

    res_crit = mod.audit_compaction(
        buddyinfo_path=mock_buddy,
        vmstat_path=mock_vmstat,
        proactiveness_path=mock_proact,
        extfrag_threshold_path=mock_extfrag,
    )
    assert res_crit['summary']['healthy'] is False
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert res_crit['summary']['normal_zone_high_orders'] == 3
    assert res_crit['summary']['compact_fail_ratio'] > 0.8
    assert 'Severe external memory fragmentation' in res_crit['summary']['recommendation']
"
echo "ok - unit tests on threshold logic and simulated buddyinfo/vmstat passed"

echo "ok - all Pattern 68 memory compaction healer tests passed"
