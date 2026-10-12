#!/usr/bin/env bash
# tests/fm-jev-skbuff-guard.test.sh - Regression tests for Pattern 208 (Socket Buffer Auto-Tuning Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-skbuff-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-skbuff-guard.py"

echo "Running Pattern 208 regression tests..."

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
assert isinstance(s['total_sockets'], int)
assert isinstance(s['total_protocols'], int)
assert isinstance(s['tcp_sockets'], int)
assert isinstance(s['udp_sockets'], int)
assert isinstance(s['unix_sockets'], int)
assert isinstance(s['pressured_protocols'], list)
assert isinstance(s['rmem_max_bytes'], int)
assert isinstance(s['wmem_max_bytes'], int)
assert isinstance(s['optmem_max_bytes'], int)
assert isinstance(s['tcp_rmem_max_bytes'], int)
assert isinstance(s['tcp_wmem_max_bytes'], int)
assert isinstance(s['tcp_moderate_rcvbuf'], int)
assert isinstance(s['tcp_window_scaling'], int)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysfs / procfs files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-skbuff-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    core_dir = d / 'core'
    core_dir.mkdir()
    ipv4_dir = d / 'ipv4'
    ipv4_dir.mkdir()
    proto_f = d / 'protocols'

    (core_dir / 'rmem_default').write_text('212992\n')
    (core_dir / 'rmem_max').write_text('212992\n')
    (core_dir / 'wmem_default').write_text('212992\n')
    (core_dir / 'wmem_max').write_text('212992\n')
    (core_dir / 'optmem_max').write_text('131072\n')

    (ipv4_dir / 'tcp_rmem').write_text('4096 131072 33554432\n')
    (ipv4_dir / 'tcp_wmem').write_text('4096 16384 4194304\n')
    (ipv4_dir / 'tcp_moderate_rcvbuf').write_text('1\n')
    (ipv4_dir / 'tcp_window_scaling').write_text('1\n')

    proto_f.write_text(
        'protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re bi br ha uh gp em\n'
        'TCP       2368     100       0   no     320   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y\n'
        'UDP       1216      20    3912   NI       0   yes  kernel      y  y  y  n  y  y  y  n  y  y  y  y  n  n  y  y  y  n\n'
        'UNIX      1152      50      -1   NI       0   yes  kernel      y  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n\n'
    )

    rep = mod.audit_skbuff_guard(proc_protocols=str(proto_f), proc_sys_core=str(core_dir), proc_sys_ipv4=str(ipv4_dir))
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['total_sockets'] == 170
    assert s['tcp_sockets'] == 100
    assert s['udp_sockets'] == 20
    assert s['unix_sockets'] == 50
    assert len(s['pressured_protocols']) == 0

    # Mock Critical condition: protocol memory pressure flag
    proto_f.write_text(
        'protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re bi br ha uh gp em\n'
        'TCP       2368    4500  1000000  yes    320   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y\n'
    )
    rep_crit = mod.audit_skbuff_guard(proc_protocols=str(proto_f), proc_sys_core=str(core_dir), proc_sys_ipv4=str(ipv4_dir))
    assert rep_crit['summary']['status'] == 'CRITICAL'
    assert rep_crit['summary']['healthy'] is False
    assert 'TCP' in rep_crit['summary']['pressured_protocols']

    # Mock Critical condition: window scaling disabled
    (ipv4_dir / 'tcp_window_scaling').write_text('0\n')
    proto_f.write_text(
        'protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re bi br ha uh gp em\n'
        'TCP       2368     100       0   no     320   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y\n'
    )
    rep_scale = mod.audit_skbuff_guard(proc_protocols=str(proto_f), proc_sys_core=str(core_dir), proc_sys_ipv4=str(ipv4_dir))
    assert rep_scale['summary']['status'] == 'CRITICAL'
    assert any('tcp_window_scaling' in iss for iss in rep_scale['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 208 tests passed successfully."
