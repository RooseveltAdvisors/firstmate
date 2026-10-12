#!/usr/bin/env bash
# tests/fm-jev-ecn-guard.test.sh - Regression tests for Pattern 191 (TCP ECN & CE Mark Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ecn-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ecn-guard.py"

echo "Running Pattern 191 regression tests..."

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
assert 'tcp_ecn' in s
assert 'tcp_ecn_fallback' in s
assert 'delivered_segments' in s
assert 'delivered_ce_marks' in s
assert 'ce_ratio_pct' in s
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
mod = import_module('fm-jev-ecn-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ecn_f = d / 'tcp_ecn'
    fallback_f = d / 'tcp_ecn_fallback'
    netstat_f = d / 'netstat'

    ecn_f.write_text('2\n')
    fallback_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPDelivered TCPDeliveredCE TCPHystartTrainDetect TCPHystartDelayDetect TCPHystartTrainCwnd TCPHystartDelayCwnd
TcpExt: 1000000 10 500 200 10000 20000
''')

    # Case 1: Nominal (server-only with fallback)
    res = mod.audit_ecn(
        tcp_ecn_file=str(ecn_f),
        tcp_ecn_fallback_file=str(fallback_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_ecn'] == 2
    assert res['summary']['tcp_ecn_fallback'] == 1
    assert res['summary']['delivered_segments'] == 1000000
    assert res['summary']['delivered_ce_marks'] == 10

    # Case 2: Full ECN (1) with fallback disabled (0) -> CRITICAL
    ecn_f.write_text('1\n')
    fallback_f.write_text('0\n')
    res2 = mod.audit_ecn(
        tcp_ecn_file=str(ecn_f),
        tcp_ecn_fallback_file=str(fallback_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('blackhole' in iss for iss in res2['summary']['issues'])

    # Case 3: ECN completely disabled (0) -> WARNING
    ecn_f.write_text('0\n')
    fallback_f.write_text('1\n')
    res3 = mod.audit_ecn(
        tcp_ecn_file=str(ecn_f),
        tcp_ecn_fallback_file=str(fallback_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('disabled' in iss for iss in res3['summary']['issues'])

    # Case 4: Excessive CE marks (>= 5%) -> WARNING
    ecn_f.write_text('2\n')
    netstat_f.write_text('''TcpExt: TCPDelivered TCPDeliveredCE TCPHystartTrainDetect TCPHystartDelayDetect TCPHystartTrainCwnd TCPHystartDelayCwnd
TcpExt: 100000 6000 500 200 10000 20000
''')
    res4 = mod.audit_ecn(
        tcp_ecn_file=str(ecn_f),
        tcp_ecn_fallback_file=str(fallback_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('bufferbloat' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 191 regression tests passed: 6/6 tests ok"
