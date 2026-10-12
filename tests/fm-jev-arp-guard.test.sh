#!/usr/bin/env bash
# tests/fm-jev-arp-guard.test.sh - Regression tests for Pattern 204 (ARP Table Saturation Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-arp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-arp-guard.py"

echo "Running Pattern 204 regression tests..."

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
assert isinstance(s['total_entries'], int)
assert isinstance(s['resolved_entries'], int)
assert isinstance(s['incomplete_entries'], int)
assert isinstance(s['gc_thresh1'], int)
assert isinstance(s['gc_thresh2'], int)
assert isinstance(s['gc_thresh3'], int)
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-arp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sys_dir = d / 'default'
    sys_dir.mkdir()
    arp_f = d / 'arp'

    (sys_dir / 'gc_thresh1').write_text('128\n')
    (sys_dir / 'gc_thresh2').write_text('512\n')
    (sys_dir / 'gc_thresh3').write_text('1024\n')
    (sys_dir / 'gc_stale_time').write_text('60\n')
    (sys_dir / 'unres_qlen').write_text('3\n')

    # Mock clean ARP table
    arp_f.write_text(
        'IP address       HW type     Flags       HW address            Mask     Device\n'
        '192.168.0.1      0x1         0x2         00:11:22:33:44:55     *        enp7s0\n'
        '192.168.0.2      0x1         0x2         00:11:22:33:44:66     *        enp7s0\n'
        '192.168.0.3      0x1         0x0         00:00:00:00:00:00     *        enp7s0\n'
    )

    rep = mod.audit_arp(proc_arp=str(arp_f), proc_sys_neigh=str(sys_dir))
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['total_entries'] == 3
    assert s['resolved_entries'] == 2
    assert s['incomplete_entries'] == 1

    # Mock Critical condition (total >= gc_thresh3)
    lines = ['IP address       HW type     Flags       HW address            Mask     Device\n']
    for i in range(1025):
        lines.append(f'10.0.0.{i} 0x1 0x2 00:11:22:33:44:55 * eth0\n')
    arp_f.write_text(''.join(lines))

    rep2 = mod.audit_arp(proc_arp=str(arp_f), proc_sys_neigh=str(sys_dir))
    assert rep2['summary']['status'] == 'CRITICAL'
    assert rep2['summary']['healthy'] is False
    assert rep2['summary']['total_entries'] == 1025
"
echo "ok - mocked unit tests pass"

echo "All Pattern 204 tests passed successfully."
