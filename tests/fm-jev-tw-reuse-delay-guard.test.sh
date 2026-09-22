#!/usr/bin/env bash
# tests/fm-jev-tw-reuse-delay-guard.test.sh - Regression tests for Pattern 183 (TCP TIME_WAIT Reuse Delay Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tw-reuse-delay-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tw-reuse-delay-guard.py"

echo "Running Pattern 183 regression tests..."

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
assert 'tcp_tw_reuse_delay_ms' in s
assert 'tcp_tw_reuse' in s
assert 'tcp_fin_timeout_sec' in s
assert 'tw_total' in s
assert 'tw_recycled' in s
assert 'tw_overflow' in s
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
mod = import_module('fm-jev-tw-reuse-delay-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    delay_f = d / 'tcp_tw_reuse_delay'
    reuse_f = d / 'tcp_tw_reuse'
    fin_f = d / 'tcp_fin_timeout'
    netstat_f = d / 'netstat'

    delay_f.write_text('1000\n')
    reuse_f.write_text('2\n')
    fin_f.write_text('60\n')
    netstat_f.write_text('''TcpExt: TW TWRecycled TWKilled PAWSTimewait TCPTimeWaitOverflow TCPACKSkippedTimeWait
TcpExt: 5000 500 0 10 0 5
''')

    # Case 1: Nominal
    res = mod.audit_tw_reuse_delay(
        delay_file=str(delay_f),
        reuse_file=str(reuse_f),
        fin_timeout_file=str(fin_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_tw_reuse_delay_ms'] == 1000
    assert res['summary']['tcp_tw_reuse'] == 2
    assert res['summary']['tw_overflow'] == 0

    # Case 2: Aggressively low delay -> WARNING
    delay_f.write_text('50\n')
    res2 = mod.audit_tw_reuse_delay(
        delay_file=str(delay_f),
        reuse_file=str(reuse_f),
        fin_timeout_file=str(fin_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('Aggressively low TIME_WAIT reuse delay' in iss for iss in res2['summary']['issues'])

    # Case 3: Reuse disabled -> WARNING
    delay_f.write_text('1000\n')
    reuse_f.write_text('0\n')
    res3 = mod.audit_tw_reuse_delay(
        delay_file=str(delay_f),
        reuse_file=str(reuse_f),
        fin_timeout_file=str(fin_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('TCP TIME_WAIT reuse disabled' in iss for iss in res3['summary']['issues'])

    # Case 4: TIME_WAIT overflow -> WARNING
    reuse_f.write_text('2\n')
    netstat_f.write_text('''TcpExt: TW TWRecycled TWKilled PAWSTimewait TCPTimeWaitOverflow TCPACKSkippedTimeWait
TcpExt: 5000 500 0 10 12 5
''')
    res4 = mod.audit_tw_reuse_delay(
        delay_file=str(delay_f),
        reuse_file=str(reuse_f),
        fin_timeout_file=str(fin_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('TIME_WAIT hash table overflow detected' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 183 regression tests passed: 6/6 tests ok"
