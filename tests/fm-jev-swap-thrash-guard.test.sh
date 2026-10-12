#!/usr/bin/env bash
# tests/fm-jev-swap-thrash-guard.test.sh - Regression tests for Pattern 79 (Swap Thrash Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-swap-thrash-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-swap-thrash-guard.py"

echo "Running Pattern 79 regression tests..."

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
assert 'psi' in data
assert 'meminfo_kb' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'swap_total_mb' in s
assert 'swap_used_mb' in s
assert 'swap_saturation_pct' in s
assert 'psi_some_avg10' in s
assert 'psi_full_avg10' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs files
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-swap-thrash-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_vmstat = os.path.join(tmp_dir, 'vmstat')
    mock_meminfo = os.path.join(tmp_dir, 'meminfo')
    mock_psi = os.path.join(tmp_dir, 'memory_psi')

    with open(mock_vmstat, 'w') as f:
        f.write('pswpin 100\npswpout 200\npgfault 1000\npgmajfault 50\noom_kill 0\ncompact_stall 10\n')

    with open(mock_meminfo, 'w') as f:
        f.write('SwapTotal:      1048576 kB\n') # 1 GB
        f.write('SwapFree:        524288 kB\n') # 500 MB (50% sat)
        f.write('SwapCached:       10240 kB\n')
        f.write('MemTotal:       4194304 kB\n')
        f.write('MemAvailable:   2097152 kB\n')

    with open(mock_psi, 'w') as f:
        f.write('some avg10=0.50 avg60=0.20 avg300=0.10 total=1000\n')
        f.write('full avg10=0.10 avg60=0.05 avg300=0.01 total=200\n')

    # Audit under normal conditions
    res = mod.audit_swap_thrashing(
        vmstat_path=mock_vmstat,
        meminfo_path=mock_meminfo,
        psi_path=mock_psi,
        warn_swap_pct=85.0,
        crit_swap_pct=95.0,
        warn_psi_some=10.0,
        crit_psi_some=30.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['swap_saturation_pct'] == 50.0
    assert s['psi_some_avg10'] == 0.50
    assert s['pgmajfault_total'] == 50

    # Test WARNING on high swap saturation
    with open(mock_meminfo, 'w') as f:
        f.write('SwapTotal:      1048576 kB\n')
        f.write('SwapFree:        104857 kB\n') # ~90% used
        f.write('SwapCached:       10240 kB\n')
    res_warn_swap = mod.audit_swap_thrashing(
        vmstat_path=mock_vmstat,
        meminfo_path=mock_meminfo,
        psi_path=mock_psi,
        warn_swap_pct=85.0,
        crit_swap_pct=95.0,
    )
    assert res_warn_swap['summary']['status'] == 'WARNING'
    assert any('swap saturation' in iss.lower() for iss in res_warn_swap['summary']['issues'])

    # Test CRITICAL on critical PSI memory pressure stall
    with open(mock_psi, 'w') as f:
        f.write('some avg10=45.00 avg60=20.00 avg300=10.00 total=10000\n')
        f.write('full avg10=20.00 avg60=10.00 avg300=5.00 total=5000\n')
    res_crit_psi = mod.audit_swap_thrashing(
        vmstat_path=mock_vmstat,
        meminfo_path=mock_meminfo,
        psi_path=mock_psi,
        crit_psi_some=30.0,
    )
    assert res_crit_psi['summary']['status'] == 'CRITICAL'
    assert any('pressure stall' in iss.lower() for iss in res_crit_psi['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 79 tests passed!"
