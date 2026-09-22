#!/usr/bin/env bash
# tests/fm-jev-cgroup-guard.test.sh - Regression tests for Pattern 76 (Cgroup Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-cgroup-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-cgroup-guard.py"

echo "Running Pattern 76 regression tests..."

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
assert 'cgroup_path' in data
assert 'summary' in data
assert 'pressure' in data
assert 'events' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'pids_current' in s
assert 'pids_max' in s
assert 'memory_current_bytes' in s
assert 'memory_pressure_avg10' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked cgroup tree
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-cgroup-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_cgroup = os.path.join(tmp_dir, 'mock_slice')
    os.makedirs(mock_cgroup, exist_ok=True)

    # Write cgroup files
    with open(os.path.join(mock_cgroup, 'memory.current'), 'w') as f:
        f.write('1073741824\n') # 1 GB
    with open(os.path.join(mock_cgroup, 'memory.max'), 'w') as f:
        f.write('2147483648\n') # 2 GB (50% sat)
    with open(os.path.join(mock_cgroup, 'memory.events'), 'w') as f:
        f.write('low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n')
    with open(os.path.join(mock_cgroup, 'memory.pressure'), 'w') as f:
        f.write('some avg10=0.50 avg60=0.20 avg300=0.10 total=1000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n')

    with open(os.path.join(mock_cgroup, 'pids.current'), 'w') as f:
        f.write('100\n')
    with open(os.path.join(mock_cgroup, 'pids.max'), 'w') as f:
        f.write('1000\n') # 10% sat
    with open(os.path.join(mock_cgroup, 'pids.events'), 'w') as f:
        f.write('max 0\n')

    with open(os.path.join(mock_cgroup, 'cpu.pressure'), 'w') as f:
        f.write('some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n')
    with open(os.path.join(mock_cgroup, 'io.pressure'), 'w') as f:
        f.write('some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n')

    # Audit under normal thresholds
    res = mod.audit_cgroup(
        cgroup_dir=mock_cgroup,
        warn_pid_pct=50.0,
        crit_pid_pct=80.0,
        warn_mem_pressure=10.0,
        crit_mem_pressure=40.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['pids_current'] == 100
    assert s['pids_max'] == 1000
    assert s['pid_saturation_pct'] == 10.0
    assert s['memory_current_bytes'] == 1073741824
    assert s['memory_saturation_pct'] == 50.0
    assert s['memory_pressure_avg10'] == 0.50

    # Test WARNING on high PID saturation
    with open(os.path.join(mock_cgroup, 'pids.current'), 'w') as f:
        f.write('650\n') # 65% > 50%
    res_warn = mod.audit_cgroup(
        cgroup_dir=mock_cgroup,
        warn_pid_pct=50.0,
        crit_pid_pct=80.0,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('PID saturation' in iss for iss in res_warn['summary']['issues'])

    # Test CRITICAL on high memory pressure
    with open(os.path.join(mock_cgroup, 'memory.pressure'), 'w') as f:
        f.write('some avg10=45.00 avg60=30.00 avg300=10.00 total=5000\n')
    res_crit = mod.audit_cgroup(
        cgroup_dir=mock_cgroup,
        crit_mem_pressure=40.0,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 76 tests passed!"
