#!/usr/bin/env bash
# tests/fm-jev-retrans-fail-guard.test.sh - Regression tests for Pattern 165 (TCP Retransmit Failure Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-retrans-fail-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-retrans-fail-guard.py"

echo "Running Pattern 165 regression tests..."

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
assert 'sysctls' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'retrans_fail' in s
assert 'tcp_retries1' in s
assert 'tcp_retries2' in s
assert 'traffic_fail_ratio_pct' in s
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
mod = import_module('fm-jev-retrans-fail-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    r1_f = d / 'tcp_retries1'
    r2_f = d / 'tcp_retries2'

    r1_f.write_text('3\n')
    r2_f.write_text('15\n')
    netstat_f.write_text('''TcpExt: TCPRetransFail TCPFastRetrans TCPSlowStartRetrans TCPLostRetransmit TCPTimeouts TCPDelivered
TcpExt: 100 50000 2000 1000 10000 10000000
''')

    # Case 1: Nominal
    res = mod.audit_retrans_fail(
        netstat_file=str(netstat_f),
        retries1_file=str(r1_f),
        retries2_file=str(r2_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['retrans_fail'] == 100
    assert res['summary']['tcp_retries1'] == 3
    assert res['summary']['tcp_retries2'] == 15

    # Case 2: High failure rate of traffic -> WARNING
    netstat_f.write_text('''TcpExt: TCPRetransFail TCPFastRetrans TCPSlowStartRetrans TCPLostRetransmit TCPTimeouts TCPDelivered
TcpExt: 50000 50000 2000 1000 10000 1000000
''')
    res2 = mod.audit_retrans_fail(
        netstat_file=str(netstat_f),
        retries1_file=str(r1_f),
        retries2_file=str(r2_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('retransmission failure rate' in iss for iss in res2['summary']['issues'])

    # Case 3: Low tcp_retries2 -> WARNING
    r2_f.write_text('2\n')
    netstat_f.write_text('''TcpExt: TCPRetransFail TCPFastRetrans TCPSlowStartRetrans TCPLostRetransmit TCPTimeouts TCPDelivered
TcpExt: 100 50000 2000 1000 10000 10000000
''')
    res3 = mod.audit_retrans_fail(
        netstat_file=str(netstat_f),
        retries1_file=str(r1_f),
        retries2_file=str(r2_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('low tcp_retries2 threshold' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 165 regression tests passed!"
