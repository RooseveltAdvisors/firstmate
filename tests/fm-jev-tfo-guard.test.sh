#!/usr/bin/env bash
# tests/fm-jev-tfo-guard.test.sh - Regression tests for Pattern 105 (TCP Fast Open Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tfo-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tfo-guard.py"

echo "Running Pattern 105 regression tests..."

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
assert 'bitmask' in data
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_fastopen_raw' in s
assert 'client_tfo_enabled' in s
assert 'server_tfo_enabled' in s
assert 'blackholes_detected' in s
assert 'listen_overflows' in s
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
mod = import_module('fm-jev-tfo-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    fastopen_file = d / 'tcp_fastopen'
    timeout_file = d / 'tcp_fastopen_blackhole_timeout_sec'
    netstat_file = d / 'netstat'

    fastopen_file.write_text('3\n')  # 0x1 | 0x2 -> client and server enabled
    timeout_file.write_text('3600\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPFastOpenActive TCPFastOpenActiveFail TCPFastOpenPassive TCPFastOpenPassiveFail TCPFastOpenListenOverflow TCPFastOpenCookieReqd TCPFastOpenBlackholeDetected
TcpExt: 0 100 2 50 0 0 10 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_tfo(
        fastopen_file=str(fastopen_file),
        blackhole_timeout_file=str(timeout_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['client_tfo_enabled'] is True
    assert res['summary']['server_tfo_enabled'] is True
    assert res['summary']['blackholes_detected'] == 0
    assert res['summary']['listen_overflows'] == 0

    # Case 2: Blackhole detected warning
    bh_netstat = mock_netstat.replace(' 0 100 2 50 0 0 10 0', ' 0 100 2 50 0 0 10 1')
    netstat_file.write_text(bh_netstat)
    res2 = mod.audit_tfo(
        fastopen_file=str(fastopen_file),
        blackhole_timeout_file=str(timeout_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('blackholes detected' in iss for iss in res2['summary']['issues'])

    # Case 3: High listen queue overflow
    ovf_netstat = mock_netstat.replace(' 0 100 2 50 0 0 10 0', ' 0 100 2 50 0 25 10 0')
    netstat_file.write_text(ovf_netstat)
    res3 = mod.audit_tfo(
        fastopen_file=str(fastopen_file),
        blackhole_timeout_file=str(timeout_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('listen queue overflow' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 105 tests passed!"
