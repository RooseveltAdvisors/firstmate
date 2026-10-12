#!/usr/bin/env bash
# tests/fm-jev-unix-guard.test.sh - Regression tests for Pattern 206 (UNIX Domain Socket Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-unix-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-unix-guard.py"

echo "Running Pattern 206 regression tests..."

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
assert isinstance(s['stream_sockets'], int)
assert isinstance(s['dgram_sockets'], int)
assert isinstance(s['listening_sockets'], int)
assert isinstance(s['connected_sockets'], int)
assert isinstance(s['filesystem_paths'], int)
assert isinstance(s['abstract_paths'], int)
assert isinstance(s['anonymous_paths'], int)
assert isinstance(s['max_dgram_qlen'], int)
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
mod = import_module('fm-jev-unix-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sys_dir = d / 'sys_unix'
    sys_dir.mkdir()
    unix_f = d / 'proc_unix'

    (sys_dir / 'max_dgram_qlen').write_text('512\n')

    # Mock clean unix table
    unix_f.write_text(
        'Num       RefCount Protocol Flags    Type St Inode Path\n'
        '00000000: 00000002 00000000 00010000 0001 01 1001 /run/app.sock\n'
        '00000000: 00000003 00000000 00000000 0001 03 1002\n'
        '00000000: 00000001 00000000 00000000 0002 01 1003 @/tmp/dbus-test\n'
    )

    rep = mod.audit_unix_sockets(proc_net_unix=str(unix_f), proc_sys_unix=str(sys_dir))
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['total_sockets'] == 3
    assert s['stream_sockets'] == 2
    assert s['dgram_sockets'] == 1
    assert s['listening_sockets'] == 1
    assert s['connected_sockets'] == 1
    assert s['filesystem_paths'] == 1
    assert s['abstract_paths'] == 1
    assert s['anonymous_paths'] == 1
    assert s['max_refcount'] == 3

    # Mock Critical condition (total > 5000)
    lines = ['Num       RefCount Protocol Flags    Type St Inode Path\n']
    for i in range(5005):
        lines.append(f'00000000: 00000002 00000000 00000000 0001 03 {i}\n')
    unix_f.write_text(''.join(lines))

    rep2 = mod.audit_unix_sockets(proc_net_unix=str(unix_f), proc_sys_unix=str(sys_dir))
    assert rep2['summary']['status'] == 'CRITICAL'
    assert rep2['summary']['healthy'] is False
    assert rep2['summary']['total_sockets'] == 5005
"
echo "ok - mocked unit tests pass"

echo "All Pattern 206 tests passed successfully."
