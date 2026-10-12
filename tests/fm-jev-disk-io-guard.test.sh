#!/usr/bin/env bash
# tests/fm-jev-disk-io-guard.test.sh - Regression tests for Pattern 87 (Disk I/O & Latency Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-disk-io-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-disk-io-guard.py"

echo "Running Pattern 87 regression tests..."

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
assert 'devices' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'devices_count' in s
assert 'max_in_flight' in s
assert 'total_reads' in s
assert 'total_writes' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked diskstats and sysfs rotational flags
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-disk-io-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_diskstats = os.path.join(tmp_dir, 'diskstats')
    mock_sysfs = os.path.join(tmp_dir, 'sys_block')

    # Setup mock sysfs
    os.makedirs(os.path.join(mock_sysfs, 'nvme0n1', 'queue'), exist_ok=True)
    with open(os.path.join(mock_sysfs, 'nvme0n1', 'queue', 'rotational'), 'w') as f:
        f.write('0\n')

    os.makedirs(os.path.join(mock_sysfs, 'sda', 'queue'), exist_ok=True)
    with open(os.path.join(mock_sysfs, 'sda', 'queue', 'rotational'), 'w') as f:
        f.write('0\n')

    os.makedirs(os.path.join(mock_sysfs, 'sdb', 'queue'), exist_ok=True)
    with open(os.path.join(mock_sysfs, 'sdb', 'queue', 'rotational'), 'w') as f:
        f.write('1\n')

    # Case 1: All healthy (nvme0n1, sda, sdb, and filtered partitions/loops)
    with open(mock_diskstats, 'w') as f:
        f.write('''   7       0 loop0 10 0 100 10 5 0 50 5 0 0 15 15
   8       0 sda 1000 0 10000 500 2000 0 20000 1000 2 0 1500 1500
   8       1 sda1 500 0 5000 250 1000 0 10000 500 1 0 750 750
   8      16 sdb 500 0 5000 5000 500 0 5000 50000 0 0 55000 55000
 259       0 nvme0n1 10000 0 100000 1000 10000 0 100000 2000 1 0 3000 3000
 259       1 nvme0n1p1 5000 0 50000 500 5000 0 50000 1000 0 0 1500 1500
''')

    res = mod.audit_disk_io(
        diskstats_path=mock_diskstats,
        sysfs_path=mock_sysfs,
        warn_in_flight=32,
        crit_in_flight=64,
        warn_latency_ms=100.0,
        warn_rotational_latency_ms=250.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['devices_count'] == 3  # sda, sdb, nvme0n1 (loop0, sda1, nvme0n1p1 filtered)
    assert s['max_in_flight'] == 2
    assert res['devices']['nvme0n1']['type'] == 'NVMe'
    assert res['devices']['sda']['type'] == 'SSD'
    assert res['devices']['sdb']['type'] == 'HDD'

    # Case 2: Warning on elevated in-flight
    res_warn = mod.audit_disk_io(
        diskstats_path=mock_diskstats,
        sysfs_path=mock_sysfs,
        warn_in_flight=2,  # triggers warning on max_in_flight=2
        crit_in_flight=64,
    )
    assert res_warn['summary']['status'] == 'WARNING'

    # Case 3: Critical on high queue depth
    res_crit = mod.audit_disk_io(
        diskstats_path=mock_diskstats,
        sysfs_path=mock_sysfs,
        warn_in_flight=1,
        crit_in_flight=2,  # triggers critical on max_in_flight=2
    )
    assert res_crit['summary']['status'] == 'CRITICAL'

    # Case 4: Warning on latency exceeding threshold
    res_lat = mod.audit_disk_io(
        diskstats_path=mock_diskstats,
        sysfs_path=mock_sysfs,
        warn_latency_ms=0.01,  # triggers latency warning on SSD
    )
    assert res_lat['summary']['status'] == 'WARNING'
    assert any('elevated' in iss for iss in res_lat['summary']['issues'])

    # Case 5: Fail-open on missing file
    res_missing = mod.audit_disk_io(diskstats_path='/nonexistent/diskstats')
    assert res_missing['summary']['healthy'] is True
    assert res_missing['summary']['devices_count'] == 0
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 87 tests passed!"
