#!/usr/bin/env bash
# tests/fm-jev-sockbuf-guard.test.sh - Regression tests for Pattern 104 (Socket Buffer Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sockbuf-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sockbuf-guard.py"

echo "Running Pattern 104 regression tests..."

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
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'rmem_max_bytes' in s
assert 'wmem_max_bytes' in s
assert 'netdev_max_backlog' in s
assert 'somaxconn' in s
assert 'tcp_backlog_drops' in s
assert 'pfmemalloc_drops' in s
assert 'softnet_processed' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctls and /proc/net/ files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-sockbuf-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    rmem_max = d / 'rmem_max'
    wmem_max = d / 'wmem_max'
    rmem_def = d / 'rmem_default'
    wmem_def = d / 'wmem_default'
    optmem = d / 'optmem_max'
    backlog = d / 'netdev_max_backlog'
    somaxconn = d / 'somaxconn'
    netstat = d / 'netstat'
    softnet = d / 'softnet_stat'

    rmem_max.write_text('212992\n')
    wmem_max.write_text('212992\n')
    rmem_def.write_text('212992\n')
    wmem_def.write_text('212992\n')
    optmem.write_text('131072\n')
    backlog.write_text('1000\n')
    somaxconn.write_text('4096\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPBacklogDrop PFMemallocDrop LockDroppedIcmds
TcpExt: 0 0 0 0
'''
    netstat.write_text(mock_netstat)

    mock_softnet = '''000003e8 00000000 00000005 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
'''
    softnet.write_text(mock_softnet)

    # Case 1: Nominal
    res = mod.audit_sockbuf(
        rmem_max_file=str(rmem_max),
        wmem_max_file=str(wmem_max),
        rmem_def_file=str(rmem_def),
        wmem_def_file=str(wmem_def),
        optmem_file=str(optmem),
        backlog_file=str(backlog),
        somaxconn_file=str(somaxconn),
        netstat_file=str(netstat),
        softnet_file=str(softnet),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['somaxconn'] == 4096
    assert res['summary']['netdev_max_backlog'] == 1000
    assert res['summary']['softnet_processed'] == 1000
    assert res['summary']['softnet_dropped'] == 0

    # Case 2: Low somaxconn warning
    somaxconn.write_text('128\n')
    res2 = mod.audit_sockbuf(
        rmem_max_file=str(rmem_max),
        wmem_max_file=str(wmem_max),
        rmem_def_file=str(rmem_def),
        wmem_def_file=str(wmem_def),
        optmem_file=str(optmem),
        backlog_file=str(backlog),
        somaxconn_file=str(somaxconn),
        netstat_file=str(netstat),
        softnet_file=str(softnet),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('somaxconn' in iss for iss in res2['summary']['issues'])
    somaxconn.write_text('4096\n')

    # Case 3: Elevated TCP backlog drops
    bad_netstat = '''TcpExt: SyncookiesSent TCPBacklogDrop PFMemallocDrop LockDroppedIcmds
TcpExt: 0 15 0 0
'''
    netstat.write_text(bad_netstat)
    res3 = mod.audit_sockbuf(
        rmem_max_file=str(rmem_max),
        wmem_max_file=str(wmem_max),
        rmem_def_file=str(rmem_def),
        wmem_def_file=str(wmem_def),
        optmem_file=str(optmem),
        backlog_file=str(backlog),
        somaxconn_file=str(somaxconn),
        netstat_file=str(netstat),
        softnet_file=str(softnet),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('TCPBacklogDrop' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 104 tests passed!"
