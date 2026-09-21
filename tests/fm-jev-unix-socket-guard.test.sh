#!/usr/bin/env bash
# tests/fm-jev-unix-socket-guard.test.sh - Regression tests for Pattern 74 (Unix Socket Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-unix-socket-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-unix-socket-guard.py"

echo "Running Pattern 74 regression tests..."

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
assert 'unlinked_samples' in data
assert 'top_listening_sockets' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'total_unix_sockets' in s
assert 'stream_sockets' in s
assert 'dgram_sockets' in s
assert 'listening_sockets' in s
assert 'connected_sockets' in s
assert 'abstract_sockets' in s
assert 'filesystem_sockets' in s
assert 'unlinked_sockets' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked /proc/net/unix and temp directories
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-unix-socket-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_unix = os.path.join(tmp_dir, 'unix')
    real_sock = os.path.join(tmp_dir, 'real.sock')
    with open(real_sock, 'w') as f:
        f.write('') # create dummy file representing existing socket path

    mock_header = 'Num       RefCount Protocol Flags    Type St Inode Path\n'
    # Socket 1: STREAM, LISTEN (01), existing file path
    line1 = f'0000000000000001: 00000002 00000000 00010000 0001 01 10001 {real_sock}\n'
    # Socket 2: STREAM, CONNECTED (03), missing file path -> UNLINKED
    line2 = f'0000000000000002: 00000002 00000000 00010000 0001 03 10002 /tmp/nonexistent_socket_123.sock\n'
    # Socket 3: DGRAM, CONNECTED (03), abstract namespace
    line3 = f'0000000000000003: 00000002 00000000 00000000 0002 03 10003 @abstract_test\n'
    # Socket 4: STREAM, CONNECTED (03), unnamed socketpair
    line4 = f'0000000000000004: 00000003 00000000 00000000 0001 03 10004\n'

    with open(mock_unix, 'w') as f:
        f.write(mock_header + line1 + line2 + line3 + line4)

    # Audit under normal thresholds
    res = mod.audit_unix_sockets(
        proc_unix_path=mock_unix,
        scan_dirs=[tmp_dir],
        check_fs=True,
        warn_total=10,
        crit_total=20,
        warn_unlinked=5,
        crit_unlinked=10,
    )
    s = res['summary']
    assert s['total_unix_sockets'] == 4
    assert s['stream_sockets'] == 3
    assert s['dgram_sockets'] == 1
    assert s['listening_sockets'] == 1
    assert s['connected_sockets'] == 3
    assert s['abstract_sockets'] == 1
    assert s['filesystem_sockets'] == 2
    assert s['unnamed_sockets'] == 1
    assert s['unlinked_sockets'] == 1
    assert s['status'] == 'HEALTHY'

    # Test WARNING on low unlinked threshold
    res_warn = mod.audit_unix_sockets(
        proc_unix_path=mock_unix,
        scan_dirs=[tmp_dir],
        check_fs=True,
        warn_unlinked=1, # 1 >= 1 -> WARNING
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert len(res_warn['summary']['issues']) > 0

    # Test CRITICAL on low total socket threshold
    res_crit = mod.audit_unix_sockets(
        proc_unix_path=mock_unix,
        scan_dirs=[tmp_dir],
        check_fs=True,
        crit_total=3, # 4 >= 3 -> CRITICAL
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 74 tests passed!"
