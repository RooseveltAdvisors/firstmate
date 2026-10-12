#!/usr/bin/env bash
# tests/fm-jev-cpu-topology-guard.test.sh - Regression tests for Pattern 322 (CpuTopologyGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-cpu-topology-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-cpu-topology-guard.py"

echo "Running Pattern 322 regression tests..."

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
assert data['pattern'] == 322
assert data['name'] == 'cpu_topology'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_topology_healthy'], bool)
assert isinstance(data['total_cpus'], int)
assert isinstance(data['online_cpus'], int)
assert isinstance(data['offline_cpus'], int)
assert isinstance(data['isolated_cpus'], int)
assert isinstance(data['physical_cores'], int)
assert isinstance(data['dies'], int)
assert isinstance(data['sockets'], int)
assert 'smt_active' in data
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
mod = import_module('fm-jev-cpu-topology-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    cpu_d = d / 'cpu'
    cpu_d.mkdir()

    (cpu_d / 'online').write_text('0-3\n')
    (cpu_d / 'offline').write_text('\n')
    (cpu_d / 'isolated').write_text('\n')

    smt_d = cpu_d / 'smt'
    smt_d.mkdir()
    (smt_d / 'active').write_text('1\n')
    (smt_d / 'control').write_text('on\n')

    for cid in range(4):
        c = cpu_d / f'cpu{cid}'
        c.mkdir()
        top = c / 'topology'
        top.mkdir()
        (top / 'physical_package_id').write_text('0\n')
        (top / 'die_id').write_text('0\n')
        (top / 'core_id').write_text(f'{cid // 2}\n')

    res = mod.evaluate_cpu_topology(cpu_dir=str(cpu_d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['total_cpus'] == 4
    assert res['online_cpus'] == 4
    assert res['offline_cpus'] == 0
    assert res['physical_cores'] == 2
    assert res['sockets'] == 1
    assert res['smt_active'] is True
    assert len(res['issues']) == 0

    # Test offline CPU detection
    (cpu_d / 'offline').write_text('2-3\n')
    res_off = mod.evaluate_cpu_topology(cpu_dir=str(cpu_d), warn_on_offline=True)
    assert res_off['healthy'] is False
    assert res_off['status'] == 'WARNING'
    assert any('OFFLINE' in iss for iss in res_off['issues'])

    # Test SMT disabled detection
    (cpu_d / 'offline').write_text('\n')
    (smt_d / 'active').write_text('0\n')
    (smt_d / 'control').write_text('off\n')
    res_smt = mod.evaluate_cpu_topology(cpu_dir=str(cpu_d), warn_on_smt_disabled=True)
    assert res_smt['healthy'] is False
    assert res_smt['status'] == 'WARNING'
    assert any('SMT' in iss for iss in res_smt['issues'])

    # Test container fallback
    res_container = mod.evaluate_cpu_topology(cpu_dir=str(d / 'nonexistent_cpu'))
    assert res_container['healthy'] is True
    assert res_container['status'] == 'HEALTHY'
    assert res_container['total_cpus'] == 0
"
echo "ok - unit tests with mock sysfs passed"

echo "All Pattern 322 tests passed successfully!"
