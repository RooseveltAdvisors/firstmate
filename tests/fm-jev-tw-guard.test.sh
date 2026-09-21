#!/usr/bin/env bash
# tests/fm-jev-tw-guard.test.sh - Regression tests for Pattern 72 (TCP TIME_WAIT Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tw-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tw-guard.py"

echo "Running Pattern 72 regression tests..."

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
assert 'tcp_stat' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'tcp_tw_count' in s
assert 'tcp_max_tw_buckets' in s
assert 'tw_saturation_ratio' in s
assert 'tcp_tw_reuse' in s
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
mod = import_module('fm-jev-tw-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_stat = os.path.join(tmp_dir, 'sockstat')
    mock_max = os.path.join(tmp_dir, 'tcp_max_tw_buckets')
    mock_reuse = os.path.join(tmp_dir, 'tcp_tw_reuse')
    mock_fin = os.path.join(tmp_dir, 'tcp_fin_timeout')

    with open(mock_max, 'w') as f:
        f.write('10000\n')
    with open(mock_reuse, 'w') as f:
        f.write('2\n')
    with open(mock_fin, 'w') as f:
        f.write('60\n')

    # Test 1: Healthy scenario
    with open(mock_stat, 'w') as f:
        f.write('TCP: inuse 100 orphan 0 tw 50 alloc 110 mem 0\n')

    res = mod.audit_tw_buckets(
        sockstat_path=mock_stat,
        max_tw_path=mock_max,
        tw_reuse_path=mock_reuse,
        fin_timeout_path=mock_fin,
    )
    assert res['summary']['healthy'] is True
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['tcp_tw_count'] == 50

    # Test 2: Warning on elevated TIME_WAIT
    with open(mock_stat, 'w') as f:
        f.write('TCP: inuse 100 orphan 0 tw 3000 alloc 110 mem 0\n')

    res_warn = mod.audit_tw_buckets(
        sockstat_path=mock_stat,
        max_tw_path=mock_max,
        tw_reuse_path=mock_reuse,
        fin_timeout_path=mock_fin,
        warn_sat_ratio=0.20,
    )
    assert res_warn['summary']['healthy'] is False
    assert res_warn['summary']['status'] == 'WARNING'
    assert 'Elevated TIME_WAIT sockets' in res_warn['summary']['recommendation']

    # Test 3: Critical on TIME_WAIT saturation
    with open(mock_stat, 'w') as f:
        f.write('TCP: inuse 100 orphan 0 tw 9000 alloc 110 mem 0\n')

    res_crit = mod.audit_tw_buckets(
        sockstat_path=mock_stat,
        max_tw_path=mock_max,
        tw_reuse_path=mock_reuse,
        fin_timeout_path=mock_fin,
        crit_sat_ratio=0.80,
    )
    assert res_crit['summary']['healthy'] is False
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert 'TCP TIME_WAIT bucket saturation is critical' in res_crit['summary']['recommendation']
"
echo "ok - unit tests on threshold logic and simulated sockstat passed"

echo "ok - all Pattern 72 TCP TIME_WAIT guard tests passed"
