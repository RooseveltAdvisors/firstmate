#!/usr/bin/env bash
# tests/fm-jev-cpuidle-guard.test.sh - Regression tests for Pattern 319 (CpuidleGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-cpuidle-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-cpuidle-guard.py"

echo "Running Pattern 319 regression tests..."

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
assert data['pattern'] == 319
assert data['name'] == 'cpuidle'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_idle_healthy'], bool)
assert isinstance(data['driver'], str)
assert isinstance(data['governor'], str)
assert isinstance(data['available_governors'], list)
assert isinstance(data['states_count'], int)
assert isinstance(data['active_states_count'], int)
assert isinstance(data['disabled_states_count'], int)
assert isinstance(data['max_exit_latency_us'], int)
assert isinstance(data['states'], list)
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
mod = import_module('fm-jev-cpuidle-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    idle_d = d / 'cpuidle'
    idle_d.mkdir()
    (idle_d / 'current_driver').write_text('acpi_idle\n')
    (idle_d / 'current_governor').write_text('menu\n')
    (idle_d / 'available_governors').write_text('ladder menu\n')

    cpu_d = d / 'cpu'
    s0 = cpu_d / 'cpu0' / 'cpuidle' / 'state0'
    s0.mkdir(parents=True)
    (s0 / 'name').write_text('C1\n')
    (s0 / 'desc').write_text('C1 ACPI\n')
    (s0 / 'latency').write_text('1\n')
    (s0 / 'disable').write_text('0\n')
    (s0 / 'usage').write_text('100\n')
    (s0 / 'time').write_text('5000\n')

    s1 = cpu_d / 'cpu0' / 'cpuidle' / 'state1'
    s1.mkdir(parents=True)
    (s1 / 'name').write_text('C2\n')
    (s1 / 'desc').write_text('C2 ACPI\n')
    (s1 / 'latency').write_text('18\n')
    (s1 / 'disable').write_text('0\n')
    (s1 / 'usage').write_text('50\n')
    (s1 / 'time').write_text('2000\n')

    res = mod.evaluate_cpuidle(
        cpuidle_dir=str(idle_d),
        cpu_dir=str(cpu_d),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_idle_healthy'] is True
    assert res['driver'] == 'acpi_idle'
    assert res['governor'] == 'menu'
    assert res['available_governors'] == ['ladder', 'menu']
    assert res['states_count'] == 2
    assert res['active_states_count'] == 2
    assert res['disabled_states_count'] == 0
    assert res['max_exit_latency_us'] == 18
    assert len(res['issues']) == 0

    # Test warning when no driver
    (idle_d / 'current_driver').write_text('none\n')
    res_warn = mod.evaluate_cpuidle(
        cpuidle_dir=str(idle_d),
        cpu_dir=str(cpu_d),
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert any('driver' in iss for iss in res_warn['issues'])

    # Test warning when all states are disabled
    (idle_d / 'current_driver').write_text('acpi_idle\n')
    (s0 / 'disable').write_text('1\n')
    (s1 / 'disable').write_text('1\n')
    res_dis = mod.evaluate_cpuidle(
        cpuidle_dir=str(idle_d),
        cpu_dir=str(cpu_d),
    )
    assert res_dis['healthy'] is False
    assert res_dis['status'] == 'WARNING'
    assert any('disabled' in iss for iss in res_dis['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 319 regression tests passed successfully."
