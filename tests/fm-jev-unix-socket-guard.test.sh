#!/usr/bin/env bash
# tests/fm-jev-unix-socket-guard.test.sh - Regression tests for Pattern 99 (Unix Domain Socket Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-unix-socket-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-unix-socket-guard.py"

echo "Running Pattern 99 regression tests..."

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
assert isinstance(s['issues'], list)
assert 'total_sockets' in s
assert 'stream_sockets' in s
assert 'dgram_sockets' in s
assert 'named_sockets' in s
assert 'anonymous_sockets' in s
assert 'herdr_sockets' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked proc net unix and max_dgram_qlen files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-unix-socket-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    proc_unix_path = d / 'unix'
    max_dgram_path = d / 'max_dgram_qlen'

    max_dgram_path.write_text('512\n')

    # Mock unix table
    mock_unix = '''Num       RefCount Protocol Flags    Type St Inode Path
0000000000000000: 00000003 00000000 00000000 0001 03 12345 /run/systemd/journal/stdout
0000000000000000: 00000002 00000000 00000000 0002 01 12346 /run/systemd/journal/syslog
0000000000000000: 00000003 00000000 00000000 0001 03 12347 /home/jon/.config/herdr/sessions/firstmate/herdr-client.sock
0000000000000000: 00000002 00000000 00000000 0001 03 12348
'''
    proc_unix_path.write_text(mock_unix)

    # Case 1: Healthy configuration
    res = mod.audit_unix_sockets(
        proc_unix_file=str(proc_unix_path),
        max_dgram_file=str(max_dgram_path),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['total_sockets'] == 4
    assert res['summary']['stream_sockets'] == 3
    assert res['summary']['dgram_sockets'] == 1
    assert res['summary']['herdr_sockets'] == 1
    assert res['summary']['named_sockets'] == 3
    assert res['summary']['anonymous_sockets'] == 1

    # Case 2: Low max_dgram_qlen triggers warning
    max_dgram_path.write_text('128\n')
    res_low_q = mod.audit_unix_sockets(
        proc_unix_file=str(proc_unix_path),
        max_dgram_file=str(max_dgram_path),
    )
    assert res_low_q['summary']['status'] == 'WARNING'
    assert any('Low max_dgram_qlen' in iss for iss in res_low_q['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 99 tests passed!"
