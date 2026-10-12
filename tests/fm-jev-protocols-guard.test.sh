#!/usr/bin/env bash
# tests/fm-jev-protocols-guard.test.sh - Regression tests for Pattern 247 (ProtocolsGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-protocols-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-protocols-guard.py"

echo "Running Pattern 247 regression tests..."

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
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['total_protocols'], int)
assert isinstance(data['in_use_protocols_count'], int)
assert isinstance(data['total_sockets'], int)
assert isinstance(data['pressured_count'], int)
assert isinstance(data['slab_protocols_count'], int)
assert isinstance(data['tracked_memory_pages'], int)
assert isinstance(data['active_protocols'], dict)
assert isinstance(data['core_protocols_verified'], list)
assert isinstance(data['issues'], list)
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
mod = import_module('fm-jev-protocols-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    proto_f = d / 'protocols'

    # Mock nominal protocols
    proto_f.write_text(
        'protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re bi br ha uh gp em\n'
        'TCP       2368    500       0   no     320   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y\n'
        'UDP       1216     20    4000   NI       0   yes  kernel      y  y  y  n  y  y  y  n  y  y  y  y  n  n  y  y  y  n\n'
        'UNIX-STREAM 1152  900      -1   NI       0   yes  kernel      y  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n\n'
        'UNIX      1152     60      -1   NI       0   yes  kernel      y  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n\n'
        'NETLINK   1096     40      -1   NI       0   no   kernel      n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n\n'
    )

    res = mod.audit_protocols_guard(protocols_file=str(proto_f))
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['total_protocols'] == 5
    assert res['in_use_protocols_count'] == 5
    assert res['total_sockets'] == 1520
    assert res['pressured_count'] == 0
    assert len(res['issues']) == 0

    # Mock memory pressure on TCP
    proto_f.write_text(
        'protocol  size sockets  memory press maxhdr  slab module     cl co di ac io in de sh ss gs se re bi br ha uh gp em\n'
        'TCP       2368    500   15000  yes     320   yes  kernel      y  y  y  y  y  y  y  y  y  y  y  y  n  y  y  y  y  y\n'
        'UDP       1216     20    4000   NI       0   yes  kernel      y  y  y  n  y  y  y  n  y  y  y  y  n  n  y  y  y  n\n'
        'UNIX-STREAM 1152  900      -1   NI       0   yes  kernel      y  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n\n'
        'UNIX      1152     60      -1   NI       0   yes  kernel      y  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n\n'
        'NETLINK   1096     40      -1   NI       0   no   kernel      n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n  n\n'
    )

    res_pressured = mod.audit_protocols_guard(protocols_file=str(proto_f))
    assert res_pressured['status'] == 'CRITICAL', f'Expected CRITICAL, got {res_pressured[\"status\"]}'
    assert res_pressured['healthy'] is False
    assert res_pressured['pressured_count'] == 1
    assert 'TCP' in res_pressured['pressured_protocols']
    assert any('Active kernel socket memory pressure' in iss for iss in res_pressured['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "Pattern 247 regression tests complete: ALL 6 TESTS PASSED."
