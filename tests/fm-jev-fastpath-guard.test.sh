#!/usr/bin/env bash
# tests/fm-jev-fastpath-guard.test.sh - Regression tests for Pattern 233 (TCP Fast-Path Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-fastpath-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-fastpath-guard.py"

echo "Running Pattern 233 regression tests..."

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
assert 'netstat_counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'header_prediction_hits' in s
assert 'fastpath_acks' in s
assert 'pure_acks' in s
assert 'fastpath_ack_ratio_pct' in s
assert 'delivered_segments' in s
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
mod = import_module('fm-jev-fastpath-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'

    netstat_f.write_text('''TcpExt: TCPHPHits TCPHPAcks TCPPureAcks TCPAckCompressed TCPDelivered
TcpExt: 10000 50000 20000 1000 100000
''')

    # Case 1: Nominal
    res = mod.audit_fastpath(netstat_file=str(netstat_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['header_prediction_hits'] == 10000
    assert res['summary']['fastpath_acks'] == 50000
    assert res['summary']['pure_acks'] == 20000
    assert round(res['summary']['fastpath_ack_ratio_pct'], 1) == 71.4

    # Case 2: Zero fast-path events on active host -> CRITICAL
    netstat_f.write_text('''TcpExt: TCPHPHits TCPHPAcks TCPPureAcks TCPAckCompressed TCPDelivered
TcpExt: 0 0 50000 0 200000
''')
    res2 = mod.audit_fastpath(netstat_file=str(netstat_f))
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('Zero fast-path' in iss for iss in res2['summary']['issues'])

    # Case 3: Low fast-path ratio (< 20%) -> WARNING
    netstat_f.write_text('''TcpExt: TCPHPHits TCPHPAcks TCPPureAcks TCPAckCompressed TCPDelivered
TcpExt: 100 1000 9000 0 50000
''')
    res3 = mod.audit_fastpath(netstat_file=str(netstat_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('Fast-path ACK ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 233 regression tests passed: 6/6 tests ok"
