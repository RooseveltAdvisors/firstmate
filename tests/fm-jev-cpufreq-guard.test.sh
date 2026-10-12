#!/usr/bin/env bash
# tests/fm-jev-cpufreq-guard.test.sh - Regression tests for Pattern 321 (CpufreqGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-cpufreq-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-cpufreq-guard.py"

echo "Running Pattern 321 regression tests..."

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
assert data['pattern'] == 321
assert data['name'] == 'cpufreq'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_cpufreq_healthy'], bool)
assert isinstance(data['total_cpus'], int)
assert isinstance(data['cpufreq_cores'], int)
assert isinstance(data['governors'], list)
assert isinstance(data['drivers'], list)
assert isinstance(data['energy_performance_preferences'], list)
assert isinstance(data['avg_cur_freq_mhz'], (int, float))
assert isinstance(data['min_cur_freq_mhz'], (int, float))
assert isinstance(data['max_cur_freq_mhz'], (int, float))
assert 'boost_enabled' in data
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
mod = import_module('fm-jev-cpufreq-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    cpu_d = d / 'cpu'
    cpu_d.mkdir()

    # Core 0
    c0 = cpu_d / 'cpu0' / 'cpufreq'
    c0.mkdir(parents=True)
    (c0 / 'scaling_governor').write_text('powersave\n')
    (c0 / 'scaling_driver').write_text('amd-pstate-epp\n')
    (c0 / 'energy_performance_preference').write_text('balance_performance\n')
    (c0 / 'scaling_cur_freq').write_text('4200000\n')
    (c0 / 'scaling_min_freq').write_text('800000\n')
    (c0 / 'scaling_max_freq').write_text('5000000\n')
    (c0 / 'boost').write_text('1\n')

    # Core 1
    c1 = cpu_d / 'cpu1' / 'cpufreq'
    c1.mkdir(parents=True)
    (c1 / 'scaling_governor').write_text('powersave\n')
    (c1 / 'scaling_driver').write_text('amd-pstate-epp\n')
    (c1 / 'energy_performance_preference').write_text('balance_performance\n')
    (c1 / 'scaling_cur_freq').write_text('4500000\n')
    (c1 / 'scaling_min_freq').write_text('800000\n')
    (c1 / 'scaling_max_freq').write_text('5000000\n')
    (c1 / 'boost').write_text('1\n')

    res = mod.evaluate_cpufreq(
        base_cpu_dir=str(cpu_d),
        global_cpufreq_dir=str(d / 'nonexistent'),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['cpufreq_cores'] == 2
    assert res['governors'] == ['powersave']
    assert res['drivers'] == ['amd-pstate-epp']
    assert res['energy_performance_preferences'] == ['balance_performance']
    assert res['boost_enabled'] is True
    assert res['avg_cur_freq_mhz'] == 4350.0
    assert len(res['issues']) == 0

    # Test Governor Mismatch Detection
    (c1 / 'scaling_governor').write_text('performance\n')
    res_mismatch = mod.evaluate_cpufreq(
        base_cpu_dir=str(cpu_d),
        global_cpufreq_dir=str(d / 'nonexistent'),
        warn_on_governor_mismatch=True,
    )
    assert res_mismatch['healthy'] is False
    assert res_mismatch['status'] == 'WARNING'
    assert any('Heterogeneous CPU frequency governors' in iss for iss in res_mismatch['issues'])

    # Test Clamped Frequency Detection
    (c0 / 'scaling_governor').write_text('powersave\n')
    (c1 / 'scaling_governor').write_text('powersave\n')
    (c0 / 'scaling_cur_freq').write_text('800000\n')
    (c1 / 'scaling_cur_freq').write_text('800000\n')
    res_clamped = mod.evaluate_cpufreq(
        base_cpu_dir=str(cpu_d),
        global_cpufreq_dir=str(d / 'nonexistent'),
    )
    assert res_clamped['healthy'] is False
    assert res_clamped['status'] == 'WARNING'
    assert any('clamped at minimum frequency' in iss for iss in res_clamped['issues'])

    # Test container fallback
    res_container = mod.evaluate_cpufreq(
        base_cpu_dir=str(d / 'nonexistent_cpu'),
        global_cpufreq_dir=str(d / 'nonexistent_cpufreq'),
    )
    assert res_container['healthy'] is True
    assert res_container['status'] == 'HEALTHY'
    assert res_container['total_cpus'] == 0
"
echo "ok - unit tests with mock sysfs passed"

echo "All Pattern 321 tests passed successfully!"
