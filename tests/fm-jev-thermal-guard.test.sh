#!/usr/bin/env bash
# tests/fm-jev-thermal-guard.test.sh - Regression tests for Pattern 66 (Jev Thermal & CPU Throttling Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-thermal-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-thermal-guard.py"

echo "Running Pattern 66 regression tests..."

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
assert 'sensors' in data
assert 'cooling_devices' in data
assert 'max_cpu_temp_c' in data['summary']
assert 'cpu_cores_audited' in data['summary']
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
mod = import_module('fm-jev-thermal-guard')

with tempfile.TemporaryDirectory() as tmp_root:
    # Mock hwmon
    hwmon_root = os.path.join(tmp_root, 'hwmon')
    hwmon0 = os.path.join(hwmon_root, 'hwmon0')
    os.makedirs(hwmon0)
    with open(os.path.join(hwmon0, 'name'), 'w') as f:
        f.write('k10temp\n')
    with open(os.path.join(hwmon0, 'temp1_input'), 'w') as f:
        f.write('55000\n')
    with open(os.path.join(hwmon0, 'temp1_crit'), 'w') as f:
        f.write('95000\n')

    # Mock cooling devices
    thermal_root = os.path.join(tmp_root, 'thermal')
    cdev0 = os.path.join(thermal_root, 'cooling_device0')
    os.makedirs(cdev0)
    with open(os.path.join(cdev0, 'type'), 'w') as f:
        f.write('Processor\n')
    with open(os.path.join(cdev0, 'cur_state'), 'w') as f:
        f.write('0\n')
    with open(os.path.join(cdev0, 'max_state'), 'w') as f:
        f.write('4\n')

    # Mock CPU frequencies
    cpu_root = os.path.join(tmp_root, 'cpu')
    cpu0 = os.path.join(cpu_root, 'cpu0/cpufreq')
    os.makedirs(cpu0)
    with open(os.path.join(cpu0, 'scaling_cur_freq'), 'w') as f:
        f.write('4500000\n')
    with open(os.path.join(cpu0, 'scaling_max_freq'), 'w') as f:
        f.write('5000000\n')

    res = mod.audit_fleet_thermals(
        hwmon_root=hwmon_root,
        thermal_root=thermal_root,
        cpu_root=cpu_root,
        warn_cpu_temp=85.0,
        crit_cpu_temp=95.0,
    )
    assert res['summary']['healthy'] is True
    assert res['summary']['max_cpu_temp_c'] == 55.0
    assert res['summary']['cpu_cores_audited'] == 1

    # Test critical thermal spike
    with open(os.path.join(hwmon0, 'temp1_input'), 'w') as f:
        f.write('98000\n')

    res_crit = mod.audit_fleet_thermals(
        hwmon_root=hwmon_root,
        thermal_root=thermal_root,
        cpu_root=cpu_root,
        warn_cpu_temp=85.0,
        crit_cpu_temp=95.0,
    )
    assert res_crit['summary']['healthy'] is False
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert 'Critical CPU temperature: 98.0°C' in res_crit['summary']['recommendation']
"
echo "ok - unit audit on threshold logic and simulated thermals passed"

echo "ok - all Pattern 66 thermal guard tests passed"
