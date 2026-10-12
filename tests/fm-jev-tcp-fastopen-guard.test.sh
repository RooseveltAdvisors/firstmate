#!/usr/bin/env bash
# tests/fm-jev-tcp-fastopen-guard.test.sh - Regression tests for Pattern 275 (TcpFastopenGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tcp-fastopen-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tcp-fastopen-guard.py"

echo "Running Pattern 275 regression tests..."

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
assert isinstance(data['fastopen_bitmap'], int)
assert isinstance(data['client_enabled'], bool)
assert isinstance(data['server_enabled'], bool)
assert isinstance(data['blackhole_timeout_sec'], int)
assert isinstance(data['active_handshakes'], int)
assert isinstance(data['active_fails'], int)
assert isinstance(data['active_fail_pct'], float)
assert isinstance(data['passive_handshakes'], int)
assert isinstance(data['passive_fails'], int)
assert isinstance(data['passive_fail_pct'], float)
assert isinstance(data['listen_overflows'], int)
assert isinstance(data['blackhole_events'], int)
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
mod = import_module('fm-jev-tcp-fastopen-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'ipv4'
    conf.mkdir()
    (conf / 'tcp_fastopen').write_text('3\n')
    (conf / 'tcp_fastopen_blackhole_timeout_sec').write_text('3600\n')

    netstat = d / 'netstat'
    netstat.write_text(
        'TcpExt: TCPFastOpenActive TCPFastOpenActiveFail TCPFastOpenPassive TCPFastOpenPassiveFail TCPFastOpenListenOverflow TCPFastOpenCookieReqd TCPFastOpenBlackhole TCPFastOpenPassiveAltKey\n'
        'TcpExt: 100 2 50 1 0 50 0 0\n'
    )

    res = mod.audit_tcp_fastopen_guard(conf_dir=str(conf), netstat_file=str(netstat))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['fastopen_bitmap'] == 3
    assert res['client_enabled'] is True
    assert res['server_enabled'] is True
    assert res['listen_overflows'] == 0

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'ipv4'
    conf.mkdir()
    (conf / 'tcp_fastopen').write_text('1\n')
    (conf / 'tcp_fastopen_blackhole_timeout_sec').write_text('0\n')

    netstat = d / 'netstat'
    netstat.write_text(
        'TcpExt: TCPFastOpenActive TCPFastOpenActiveFail TCPFastOpenPassive TCPFastOpenPassiveFail TCPFastOpenListenOverflow TCPFastOpenCookieReqd TCPFastOpenBlackhole TCPFastOpenPassiveAltKey\n'
        'TcpExt: 10 90 0 0 250 0 10 0\n'
    )

    res = mod.audit_tcp_fastopen_guard(conf_dir=str(conf), netstat_file=str(netstat))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('listen backlog overflow' in iss for iss in res['issues'])
    assert any('middlebox blackhole' in iss for iss in res['issues'])
    assert any('outbound TFO failure rate' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 275 regression tests passed!"
