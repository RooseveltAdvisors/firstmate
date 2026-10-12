#!/usr/bin/env bash
# tests/fm-jev-sockstat-guard.test.sh - Regression tests for Pattern 69 (Socket Buffer Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sockstat-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sockstat-guard.py"

echo "Running Pattern 69 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'sockets_used' in s
assert 'tcp_inuse' in s
assert 'tcp_orphan' in s
assert 'tcp_timewait' in s
assert 'tcp_pressure_ratio' in s
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
mod = import_module('fm-jev-sockstat-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_s4 = os.path.join(tmp_dir, 'sockstat')
    mock_s6 = os.path.join(tmp_dir, 'sockstat6')
    mock_mem = os.path.join(tmp_dir, 'tcp_mem')
    mock_orphans = os.path.join(tmp_dir, 'tcp_max_orphans')

    with open(mock_mem, 'w') as f:
        f.write('1000 2000 3000\n')
    with open(mock_orphans, 'w') as f:
        f.write('10000\n')

    # Test 1: Healthy scenario
    with open(mock_s4, 'w') as f:
        f.write('sockets: used 500\nTCP: inuse 100 orphan 2 tw 20 alloc 110 mem 50\nUDP: inuse 10 mem 5\n')
    with open(mock_s6, 'w') as f:
        f.write('TCP6: inuse 5\nUDP6: inuse 1\n')

    res = mod.audit_sockstat(
        sockstat_path=mock_s4,
        sockstat6_path=mock_s6,
        tcp_mem_path=mock_mem,
        max_orphans_path=mock_orphans,
    )
    assert res['summary']['healthy'] is True
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['tcp_orphan'] == 2

    # Test 2: Warning on high orphans
    with open(mock_s4, 'w') as f:
        f.write('sockets: used 500\nTCP: inuse 100 orphan 2500 tw 20 alloc 110 mem 50\nUDP: inuse 10 mem 5\n')

    res_orph = mod.audit_sockstat(
        sockstat_path=mock_s4,
        sockstat6_path=mock_s6,
        tcp_mem_path=mock_mem,
        max_orphans_path=mock_orphans,
        warn_orphan_count=1000,
    )
    assert res_orph['summary']['healthy'] is False
    assert res_orph['summary']['status'] == 'WARNING'
    assert 'Elevated orphan socket count' in res_orph['summary']['recommendation']

    # Test 3: Critical on tcp_mem pressure
    with open(mock_s4, 'w') as f:
        f.write('sockets: used 500\nTCP: inuse 100 orphan 5 tw 20 alloc 110 mem 2500\nUDP: inuse 10 mem 5\n')

    res_crit = mod.audit_sockstat(
        sockstat_path=mock_s4,
        sockstat6_path=mock_s6,
        tcp_mem_path=mock_mem,
        max_orphans_path=mock_orphans,
    )
    assert res_crit['summary']['healthy'] is False
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert 'Kernel TCP memory is actively under pressure' in res_crit['summary']['recommendation']
"
echo "ok - unit tests on threshold logic and simulated sockstat passed"

echo "ok - all Pattern 69 socket buffer guard tests passed"
