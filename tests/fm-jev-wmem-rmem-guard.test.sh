#!/usr/bin/env bash
# tests/fm-jev-wmem-rmem-guard.test.sh - Regression tests for Pattern 190 (TCP Socket Memory Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-wmem-rmem-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-wmem-rmem-guard.py"

echo "Running Pattern 190 regression tests..."

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
assert 'sysctls' in data
assert 'netstat_counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_rmem_max' in s
assert 'tcp_wmem_max' in s
assert 'tcp_mem_high_pages' in s
assert 'tcp_moderate_rcvbuf' in s
assert 'memory_pressures' in s
assert 'rcv_q_drop' in s
assert 'abort_on_memory' in s
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
mod = import_module('fm-jev-wmem-rmem-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    rmem_f = d / 'tcp_rmem'
    wmem_f = d / 'tcp_wmem'
    mem_f = d / 'tcp_mem'
    core_rmem_f = d / 'rmem_max'
    core_wmem_f = d / 'wmem_max'
    mod_rcv_f = d / 'tcp_moderate_rcvbuf'
    netstat_f = d / 'netstat'

    rmem_f.write_text('4096 131072 33554432\n')
    wmem_f.write_text('4096 16384 4194304\n')
    mem_f.write_text('762738 1016987 1525476\n')
    core_rmem_f.write_text('212992\n')
    core_wmem_f.write_text('212992\n')
    mod_rcv_f.write_text('1\n')

    netstat_f.write_text('''TcpExt: TCPMemoryPressures TCPMemoryPressuresChrono TCPRcvQDrop TCPWqueueTooBig TCPZeroWindowDrop TCPAbortOnMemory TCPBacklogDrop PFMemallocDrop
TcpExt: 0 0 10 0 0 0 0 0
''')

    # Case 1: Nominal
    res = mod.audit_socket_memory(
        tcp_rmem_file=str(rmem_f),
        tcp_wmem_file=str(wmem_f),
        tcp_mem_file=str(mem_f),
        core_rmem_max_file=str(core_rmem_f),
        core_wmem_max_file=str(core_wmem_f),
        moderate_rcvbuf_file=str(mod_rcv_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_rmem_max'] == 33554432
    assert res['summary']['tcp_wmem_max'] == 4194304
    assert res['summary']['tcp_moderate_rcvbuf'] == 1
    assert res['summary']['memory_pressures'] == 0

    # Case 2: Abort on memory > 100 -> CRITICAL
    netstat_f.write_text('''TcpExt: TCPMemoryPressures TCPMemoryPressuresChrono TCPRcvQDrop TCPWqueueTooBig TCPZeroWindowDrop TCPAbortOnMemory TCPBacklogDrop PFMemallocDrop
TcpExt: 50 1000 10 0 0 150 0 0
''')
    res2 = mod.audit_socket_memory(
        tcp_rmem_file=str(rmem_f),
        tcp_wmem_file=str(wmem_f),
        tcp_mem_file=str(mem_f),
        core_rmem_max_file=str(core_rmem_f),
        core_wmem_max_file=str(core_wmem_f),
        moderate_rcvbuf_file=str(mod_rcv_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('TCPAbortOnMemory' in iss for iss in res2['summary']['issues'])

    # Case 3: Moderate rcvbuf == 0 with tiny rmem_max -> CRITICAL
    netstat_f.write_text('''TcpExt: TCPMemoryPressures TCPMemoryPressuresChrono TCPRcvQDrop TCPWqueueTooBig TCPZeroWindowDrop TCPAbortOnMemory TCPBacklogDrop PFMemallocDrop
TcpExt: 0 0 10 0 0 0 0 0
''')
    mod_rcv_f.write_text('0\n')
    rmem_f.write_text('4096 16384 32768\n')
    res3 = mod.audit_socket_memory(
        tcp_rmem_file=str(rmem_f),
        tcp_wmem_file=str(wmem_f),
        tcp_mem_file=str(mem_f),
        core_rmem_max_file=str(core_rmem_f),
        core_wmem_max_file=str(core_wmem_f),
        moderate_rcvbuf_file=str(mod_rcv_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('tcp_moderate_rcvbuf is disabled' in iss for iss in res3['summary']['issues'])

    # Case 4: Moderate rcvbuf == 0 but large rmem_max -> WARNING
    rmem_f.write_text('4096 131072 33554432\n')
    res4 = mod.audit_socket_memory(
        tcp_rmem_file=str(rmem_f),
        tcp_wmem_file=str(wmem_f),
        tcp_mem_file=str(mem_f),
        core_rmem_max_file=str(core_rmem_f),
        core_wmem_max_file=str(core_wmem_f),
        moderate_rcvbuf_file=str(mod_rcv_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('tcp_moderate_rcvbuf is 0' in iss for iss in res4['summary']['issues'])

    # Case 5: Memory pressures > 100 -> WARNING
    mod_rcv_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPMemoryPressures TCPMemoryPressuresChrono TCPRcvQDrop TCPWqueueTooBig TCPZeroWindowDrop TCPAbortOnMemory TCPBacklogDrop PFMemallocDrop
TcpExt: 250 5000 10 0 0 0 0 0
''')
    res5 = mod.audit_socket_memory(
        tcp_rmem_file=str(rmem_f),
        tcp_wmem_file=str(wmem_f),
        tcp_mem_file=str(mem_f),
        core_rmem_max_file=str(core_rmem_f),
        core_wmem_max_file=str(core_wmem_f),
        moderate_rcvbuf_file=str(mod_rcv_f),
        netstat_file=str(netstat_f),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('TCPMemoryPressures' in iss for iss in res5['summary']['issues'])

    # Case 6: High receive queue drops (> 10000) -> WARNING
    netstat_f.write_text('''TcpExt: TCPMemoryPressures TCPMemoryPressuresChrono TCPRcvQDrop TCPWqueueTooBig TCPZeroWindowDrop TCPAbortOnMemory TCPBacklogDrop PFMemallocDrop
TcpExt: 0 0 15000 0 0 0 0 0
''')
    res6 = mod.audit_socket_memory(
        tcp_rmem_file=str(rmem_f),
        tcp_wmem_file=str(wmem_f),
        tcp_mem_file=str(mem_f),
        core_rmem_max_file=str(core_rmem_f),
        core_wmem_max_file=str(core_wmem_f),
        moderate_rcvbuf_file=str(mod_rcv_f),
        netstat_file=str(netstat_f),
    )
    assert res6['summary']['status'] == 'WARNING'
    assert any('TCPRcvQDrop' in iss for iss in res6['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 190 regression tests passed: 6/6 tests ok"
