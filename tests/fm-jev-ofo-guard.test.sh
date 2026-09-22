#!/usr/bin/env bash
# tests/fm-jev-ofo-guard.test.sh - Regression tests for Pattern 119 (TCP Out-of-Order Queue & Memory Collapse Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ofo-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ofo-guard.py"

echo "Running Pattern 119 regression tests..."

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
assert 'tcp_rmem_min' in s
assert 'tcp_rmem_default' in s
assert 'tcp_rmem_max' in s
assert 'tcp_retrans_collapse' in s
assert 'ofo_queue' in s
assert 'ofo_drop' in s
assert 'ofo_merge' in s
assert 'rcv_collapsed' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-ofo-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    rmem_file = d / 'tcp_rmem'
    retrans_file = d / 'tcp_retrans_collapse'
    netstat_file = d / 'netstat'

    rmem_file.write_text('4096 131072 33554432\n')
    retrans_file.write_text('1\n')

    mock_netstat = '''TcpExt: TCPOFOQueue TCPOFODrop TCPOFOMerge TCPRcvCollapsed TCPRcvCoalesce TCPBacklogCoalesce TCPBacklogDrop TCPMemoryPressures
TcpExt: 1000 0 10 500 5000 200 0 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_ofo(
        rmem_file=str(rmem_file),
        retrans_file=str(retrans_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_retrans_collapse'] == 1
    assert res['summary']['tcp_rmem_max'] == 33554432
    assert res['summary']['ofo_drop'] == 0

    # Case 2: Disabled retrans_collapse warning
    retrans_file.write_text('0\n')
    res2 = mod.audit_ofo(
        rmem_file=str(rmem_file),
        retrans_file=str(retrans_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_retrans_collapse is disabled' in iss for iss in res2['summary']['issues'])
    retrans_file.write_text('1\n')

    # Case 3: Low rmem max limit warning
    rmem_file.write_text('4096 87380 8388608\n')
    res3 = mod.audit_ofo(
        rmem_file=str(rmem_file),
        retrans_file=str(retrans_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('tcp_rmem max limit is low' in iss for iss in res3['summary']['issues'])
    rmem_file.write_text('4096 131072 33554432\n')

    # Case 4: Elevated OFO drops warning
    drop_netstat = mock_netstat.replace(' 1000 0 10 500 5000 200 0 0', ' 1000 250 10 500 5000 200 0 0')
    netstat_file.write_text(drop_netstat)
    res4 = mod.audit_ofo(
        rmem_file=str(rmem_file),
        retrans_file=str(retrans_file),
        netstat_file=str(netstat_file),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('Elevated out-of-order packet drops' in iss for iss in res4['summary']['issues'])

    # Case 5: Socket backlog drops warning
    backlog_netstat = mock_netstat.replace(' 1000 0 10 500 5000 200 0 0', ' 1000 0 10 500 5000 200 15 0')
    netstat_file.write_text(backlog_netstat)
    res5 = mod.audit_ofo(
        rmem_file=str(rmem_file),
        retrans_file=str(retrans_file),
        netstat_file=str(netstat_file),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('TCP socket backlog drops detected' in iss for iss in res5['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 119 tests passed successfully!"
