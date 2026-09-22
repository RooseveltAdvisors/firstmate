#!/usr/bin/env bash
# tests/fm-jev-arp-guard.test.sh - Regression tests for Pattern 92 (Neighbor / ARP Table Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-arp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-arp-guard.py"

echo "Running Pattern 92 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'total_entries' in s
assert 'complete_entries' in s
assert 'incomplete_entries' in s
assert 'gc_thresh3' in s
assert 'saturation_pct' in s
assert 'headroom_entries' in s
assert isinstance(s['issues'], list)
assert 'sample_entries' in data
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked ARP and threshold files
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-arp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_arp = os.path.join(tmp_dir, 'arp')
    mock_t1 = os.path.join(tmp_dir, 'gc_thresh1')
    mock_t2 = os.path.join(tmp_dir, 'gc_thresh2')
    mock_t3 = os.path.join(tmp_dir, 'gc_thresh3')

    with open(mock_t1, 'w') as f: f.write('128\n')
    with open(mock_t2, 'w') as f: f.write('512\n')
    with open(mock_t3, 'w') as f: f.write('1000\n')

    # Case 1: Healthy table with 2 complete entries
    with open(mock_arp, 'w') as f:
        f.write('IP address       HW type     Flags       HW address            Mask     Device\n')
        f.write('192.168.1.1      0x1         0x2         aa:bb:cc:dd:ee:01     *        eth0\n')
        f.write('192.168.1.2      0x1         0x2         aa:bb:cc:dd:ee:02     *        eth0\n')

    res = mod.audit_arp(
        arp_path=mock_arp,
        gc_thresh1_path=mock_t1,
        gc_thresh2_path=mock_t2,
        gc_thresh3_path=mock_t3,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['total_entries'] == 2
    assert s['complete_entries'] == 2
    assert s['incomplete_entries'] == 0
    assert s['saturation_pct'] == 0.2
    assert s['headroom_entries'] == 998

    # Case 2: Warning on elevated incomplete entries
    with open(mock_arp, 'w') as f:
        f.write('IP address       HW type     Flags       HW address            Mask     Device\n')
        for i in range(30):
            f.write(f'10.0.0.{i}       0x1         0x0         00:00:00:00:00:00     *        eth0\n')

    res_warn = mod.audit_arp(
        arp_path=mock_arp,
        gc_thresh1_path=mock_t1,
        gc_thresh2_path=mock_t2,
        gc_thresh3_path=mock_t3,
        warn_incomplete=25,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert res_warn['summary']['incomplete_entries'] == 30
    assert any('Elevated count of incomplete' in iss for iss in res_warn['summary']['issues'])

    # Case 3: Critical on table saturation (>= 85%)
    with open(mock_arp, 'w') as f:
        f.write('IP address       HW type     Flags       HW address            Mask     Device\n')
        for i in range(900):
            f.write(f'10.1.{i//250}.{i%250}   0x1         0x2         aa:bb:cc:dd:ee:00     *        eth0\n')

    res_crit = mod.audit_arp(
        arp_path=mock_arp,
        gc_thresh1_path=mock_t1,
        gc_thresh2_path=mock_t2,
        gc_thresh3_path=mock_t3,
        warn_sat_pct=70.0,
        crit_sat_pct=85.0,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert res_crit['summary']['saturation_pct'] == 90.0
    assert any('Critical ARP/neighbor saturation' in iss for iss in res_crit['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 92 tests passed!"
