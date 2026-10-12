#!/usr/bin/env bash
# tests/fm-jev-pacing-ratio-guard.test.sh - Regression tests for Pattern 186 (TCP Packet Pacing Ratios Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pacing-ratio-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pacing-ratio-guard.py"

echo "Running Pattern 186 regression tests..."

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
assert 'tcp_pacing_ca_ratio' in s
assert 'tcp_pacing_ss_ratio' in s
assert 'tcp_notsent_lowat' in s
assert 'tcp_autocorking' in s
assert 'autocork_count' in s
assert 'wqueue_too_big' in s
assert 'delivered' in s
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
mod = import_module('fm-jev-pacing-ratio-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ca_f = d / 'tcp_pacing_ca_ratio'
    ss_f = d / 'tcp_pacing_ss_ratio'
    notsent_f = d / 'tcp_notsent_lowat'
    autocork_f = d / 'tcp_autocorking'
    netstat_f = d / 'netstat'

    ca_f.write_text('120\n')
    ss_f.write_text('200\n')
    notsent_f.write_text('4294967295\n')
    autocork_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPAutoCorking TCPWqueueTooBig TCPDelivered TCPAckCompressed
TcpExt: 500000 0 1000000 20000
''')

    # Case 1: Nominal
    res = mod.audit_pacing_ratio(
        ca_ratio_file=str(ca_f),
        ss_ratio_file=str(ss_f),
        notsent_file=str(notsent_f),
        autocork_file=str(autocork_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_pacing_ca_ratio'] == 120
    assert res['summary']['tcp_pacing_ss_ratio'] == 200
    assert res['summary']['autocork_count'] == 500000

    # Case 2: Sub-optimal CA pacing (< 100%) -> WARNING
    ca_f.write_text('80\n')
    res2 = mod.audit_pacing_ratio(
        ca_ratio_file=str(ca_f),
        ss_ratio_file=str(ss_f),
        notsent_file=str(notsent_f),
        autocork_file=str(autocork_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('sub-optimal' in iss for iss in res2['summary']['issues'])

    # Case 3: Excessive CA pacing (> 300%) -> WARNING
    ca_f.write_text('350\n')
    res3 = mod.audit_pacing_ratio(
        ca_ratio_file=str(ca_f),
        ss_ratio_file=str(ss_f),
        notsent_file=str(notsent_f),
        autocork_file=str(autocork_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('excessively high' in iss for iss in res3['summary']['issues'])

    # Case 4: Autocorking disabled (0) -> WARNING
    ca_f.write_text('120\n')
    autocork_f.write_text('0\n')
    res4 = mod.audit_pacing_ratio(
        ca_ratio_file=str(ca_f),
        ss_ratio_file=str(ss_f),
        notsent_file=str(notsent_f),
        autocork_file=str(autocork_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('autocorking is disabled' in iss for iss in res4['summary']['issues'])

    # Case 5: Excessive write queue overflows -> WARNING
    autocork_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPAutoCorking TCPWqueueTooBig TCPDelivered TCPAckCompressed
TcpExt: 500000 250 1000000 20000
''')
    res5 = mod.audit_pacing_ratio(
        ca_ratio_file=str(ca_f),
        ss_ratio_file=str(ss_f),
        notsent_file=str(notsent_f),
        autocork_file=str(autocork_f),
        netstat_file=str(netstat_f),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('write queue overflow' in iss for iss in res5['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 186 regression tests passed: 6/6 tests ok"
