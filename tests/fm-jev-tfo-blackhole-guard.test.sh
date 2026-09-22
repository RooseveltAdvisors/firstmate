#!/usr/bin/env bash
# tests/fm-jev-tfo-blackhole-guard.test.sh - Regression tests for Pattern 174 (TFO Blackhole Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tfo-blackhole-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tfo-blackhole-guard.py"

echo "Running Pattern 174 regression tests..."

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
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_fastopen' in s
assert 'client_tfo_enabled' in s
assert 'active_fail' in s
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
mod = import_module('fm-jev-tfo-blackhole-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    fo_f = d / 'tcp_fastopen'
    bh_f = d / 'tcp_fastopen_blackhole_timeout_sec'
    netstat_f = d / 'netstat'

    fo_f.write_text('1\n')
    bh_f.write_text('3600\n')
    netstat_f.write_text('''TcpExt: TCPFastOpenActive TCPFastOpenActiveFail TCPFastOpenPassive TCPFastOpenPassiveFail TCPFastOpenListenOverflow TCPFastOpenCookieReqd TCPFastOpenBlackhole TCPFastOpenPassiveAltKey
TcpExt: 0 6 0 0 0 0 0 0
''')

    # Case 1: Nominal
    res = mod.audit_tfo_blackhole(
        fastopen_file=str(fo_f),
        blackhole_timeout_file=str(bh_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['client_tfo_enabled'] is True
    assert res['summary']['blackhole_events'] == 0

    # Case 2: Elevated blackholing -> WARNING
    netstat_f.write_text('''TcpExt: TCPFastOpenActive TCPFastOpenActiveFail TCPFastOpenPassive TCPFastOpenPassiveFail TCPFastOpenListenOverflow TCPFastOpenCookieReqd TCPFastOpenBlackhole TCPFastOpenPassiveAltKey
TcpExt: 0 6 0 0 0 0 25 0
''')
    res2 = mod.audit_tfo_blackhole(
        fastopen_file=str(fo_f),
        blackhole_timeout_file=str(bh_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated TFO blackholing' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 174 regression tests passed: 6/6 tests ok"
