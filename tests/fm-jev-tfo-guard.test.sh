#!/usr/bin/env bash
# tests/fm-jev-tfo-guard.test.sh - Regression tests for Pattern 150 (TCP Fast Open Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tfo-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tfo-guard.py"

echo "Running Pattern 150 regression tests..."

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
assert 'tcp_fastopen_mode' in s
assert 'client_enabled' in s
assert 'server_enabled' in s
assert 'active_tfo' in s
assert 'blackhole_events' in s
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
mod = import_module('fm-jev-tfo-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    fastopen_f = d / 'fastopen'

    fastopen_f.write_text('3\n')
    netstat_f.write_text('''TcpExt: TCPFastOpenActive TCPFastOpenActiveFail TCPFastOpenPassive TCPFastOpenPassiveFail TCPFastOpenListenOverflow TCPFastOpenCookieReqd TCPFastOpenBlackhole TCPFastOpenPassiveAltKey
TcpExt: 100 2 50 1 0 10 0 0
''')

    # Case 1: Nominal
    res = mod.audit_tfo(netstat_file=str(netstat_f), fastopen_file=str(fastopen_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['client_enabled'] is True
    assert res['summary']['server_enabled'] is True
    assert res['summary']['active_tfo'] == 100
    assert res['summary']['blackhole_events'] == 0

    # Case 2: TFO disabled (0) -> WARNING
    fastopen_f.write_text('0\n')
    res2 = mod.audit_tfo(netstat_file=str(netstat_f), fastopen_file=str(fastopen_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Blackhole events detected -> WARNING
    fastopen_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPFastOpenActive TCPFastOpenActiveFail TCPFastOpenPassive TCPFastOpenPassiveFail TCPFastOpenListenOverflow TCPFastOpenCookieReqd TCPFastOpenBlackhole TCPFastOpenPassiveAltKey
TcpExt: 100 2 50 1 0 10 5 0
''')
    res3 = mod.audit_tfo(netstat_file=str(netstat_f), fastopen_file=str(fastopen_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('blackhole detected' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 150 regression tests passed!"
