#!/usr/bin/env bash
# tests/fm-jev-slow-start-guard.test.sh - Regression tests for Pattern 199 (TCP Slow Start Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-slow-start-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-slow-start-guard.py"

echo "Running Pattern 199 regression tests..."

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
assert 'tcp_congestion_control' in s
assert 'tcp_slow_start_after_idle' in s
assert 'slow_start_retrans' in s
assert 'fast_retrans' in s
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
mod = import_module('fm-jev-slow-start-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ss_f = d / 'tcp_slow_start_after_idle'
    cc_f = d / 'tcp_congestion_control'
    avail_f = d / 'tcp_available_congestion_control'
    netstat_f = d / 'netstat'

    ss_f.write_text('1\n')
    cc_f.write_text('cubic\n')
    avail_f.write_text('reno cubic\n')
    netstat_f.write_text('''TcpExt: TCPSlowStartRetrans TCPFastRetrans TCPHystartTrainDetect TCPHystartDelayDetect
TcpExt: 1000 5000 100 50
''')

    # Case 1: Nominal
    res = mod.audit_slow_start(
        slow_start_after_idle_file=str(ss_f),
        congestion_control_file=str(cc_f),
        available_cc_file=str(avail_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_congestion_control'] == 'cubic'
    assert res['summary']['slow_start_retrans'] == 1000
    assert res['summary']['fast_retrans'] == 5000

    # Case 2: Empty congestion control -> CRITICAL
    cc_f.write_text('\n')
    res2 = mod.audit_slow_start(
        slow_start_after_idle_file=str(ss_f),
        congestion_control_file=str(cc_f),
        available_cc_file=str(avail_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('unreadable or empty' in iss for iss in res2['summary']['issues'])

    # Case 3: Slow start retrans exceeds 2x fast retrans -> CRITICAL
    cc_f.write_text('cubic\n')
    netstat_f.write_text('''TcpExt: TCPSlowStartRetrans TCPFastRetrans TCPHystartTrainDetect TCPHystartDelayDetect
TcpExt: 25000 5000 100 50
''')
    res3 = mod.audit_slow_start(
        slow_start_after_idle_file=str(ss_f),
        congestion_control_file=str(cc_f),
        available_cc_file=str(avail_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('exceed fast retransmissions' in iss for iss in res3['summary']['issues'])

    # Case 4: Reno congestion control -> WARNING
    netstat_f.write_text('''TcpExt: TCPSlowStartRetrans TCPFastRetrans TCPHystartTrainDetect TCPHystartDelayDetect
TcpExt: 1000 5000 100 50
''')
    cc_f.write_text('reno\n')
    res4 = mod.audit_slow_start(
        slow_start_after_idle_file=str(ss_f),
        congestion_control_file=str(cc_f),
        available_cc_file=str(avail_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('legacy loss-based' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 199 regression tests passed: 6/6 tests ok"
