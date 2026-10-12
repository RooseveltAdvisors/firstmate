#!/usr/bin/env bash
# tests/fm-jev-softnet-guard.test.sh - Regression tests for Pattern 70 (Network Softnet Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-softnet-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-softnet-guard.py"

echo "Running Pattern 70 regression tests..."

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
assert 'cores' in data
assert 'hot_cores' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'total_processed' in s
assert 'total_dropped' in s
assert 'total_squeeze' in s
assert 'netdev_max_backlog' in s
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
mod = import_module('fm-jev-softnet-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_stat = os.path.join(tmp_dir, 'softnet_stat')
    mock_backlog = os.path.join(tmp_dir, 'netdev_max_backlog')
    mock_budget = os.path.join(tmp_dir, 'netdev_budget')
    mock_budget_usecs = os.path.join(tmp_dir, 'netdev_budget_usecs')

    with open(mock_backlog, 'w') as f:
        f.write('1000\n')
    with open(mock_budget, 'w') as f:
        f.write('300\n')
    with open(mock_budget_usecs, 'w') as f:
        f.write('2000\n')

    # Test 1: Healthy scenario (0 drops, low squeeze)
    with open(mock_stat, 'w') as f:
        f.write('00100000 00000000 00000005 00000000 00000000 00000000\n')
        f.write('00200000 00000000 00000002 00000000 00000000 00000000\n')

    res = mod.audit_softnet(
        softnet_path=mock_stat,
        max_backlog_path=mock_backlog,
        budget_path=mock_budget,
        budget_usecs_path=mock_budget_usecs,
    )
    assert res['summary']['healthy'] is True
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['total_cores'] == 2
    assert res['summary']['total_dropped'] == 0
    assert res['summary']['total_squeeze'] == 7

    # Test 2: Warning on time squeeze
    with open(mock_stat, 'w') as f:
        f.write('00100000 00000000 00010000 00000000 00000000 00000000\n')

    res_sq = mod.audit_softnet(
        softnet_path=mock_stat,
        max_backlog_path=mock_backlog,
        budget_path=mock_budget,
        budget_usecs_path=mock_budget_usecs,
        warn_squeeze_count=1000,
    )
    assert res_sq['summary']['healthy'] is False
    assert res_sq['summary']['status'] == 'WARNING'
    assert 'Elevated NAPI time squeeze events' in res_sq['summary']['recommendation']

    # Test 3: Critical on packet drops
    with open(mock_stat, 'w') as f:
        f.write('00100000 00000500 00000000 00000000 00000000 00000000\n')

    res_crit = mod.audit_softnet(
        softnet_path=mock_stat,
        max_backlog_path=mock_backlog,
        budget_path=mock_budget,
        budget_usecs_path=mock_budget_usecs,
        warn_drop_count=100,
    )
    assert res_crit['summary']['healthy'] is False
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert 'Active packet drop detected' in res_crit['summary']['recommendation']
"
echo "ok - unit tests on threshold logic and simulated softnet_stat passed"

echo "ok - all Pattern 70 network softnet guard tests passed"
