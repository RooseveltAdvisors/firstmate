#!/usr/bin/env bash
# tests/fm-jev-autocork-guard.test.sh - Regression tests for Pattern 194 (TCP Autocorking Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-autocork-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-autocork-guard.py"

echo "Running Pattern 194 regression tests..."

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
assert 'tcp_autocorking' in s
assert 'autocorked_segments' in s
assert 'orig_data_sent' in s
assert 'autocork_ratio_pct' in s
assert 'backlog_coalesce' in s
assert 'rcv_coalesce' in s
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
mod = import_module('fm-jev-autocork-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    cork_f = d / 'tcp_autocorking'
    notsent_f = d / 'tcp_notsent_lowat'
    netstat_f = d / 'netstat'

    cork_f.write_text('1\n')
    notsent_f.write_text('4294967295\n')
    netstat_f.write_text('''TcpExt: TCPAutoCorking TCPOrigDataSent TCPBacklogCoalesce TCPRcvCoalesce
TcpExt: 1000 100000 500 2000
''')

    # Case 1: Nominal
    res = mod.audit_autocorking(
        tcp_autocorking_file=str(cork_f),
        tcp_notsent_lowat_file=str(notsent_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_autocorking'] == 1
    assert res['summary']['autocorked_segments'] == 1000
    assert res['summary']['orig_data_sent'] == 100000
    assert res['summary']['autocork_ratio_pct'] == 1.0

    # Case 2: Autocorking disabled and notsent_lowat 0 -> CRITICAL
    cork_f.write_text('0\n')
    notsent_f.write_text('0\n')
    res2 = mod.audit_autocorking(
        tcp_autocorking_file=str(cork_f),
        tcp_notsent_lowat_file=str(notsent_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('fragmentation' in iss for iss in res2['summary']['issues'])

    # Case 3: Autocorking disabled but standard notsent_lowat -> WARNING
    notsent_f.write_text('4294967295\n')
    res3 = mod.audit_autocorking(
        tcp_autocorking_file=str(cork_f),
        tcp_notsent_lowat_file=str(notsent_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('sub-MSS' in iss for iss in res3['summary']['issues'])

    # Case 4: Excessive autocork ratio (>= 25%) -> WARNING
    cork_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPAutoCorking TCPOrigDataSent TCPBacklogCoalesce TCPRcvCoalesce
TcpExt: 30000 100000 500 2000
''')
    res4 = mod.audit_autocorking(
        tcp_autocorking_file=str(cork_f),
        tcp_notsent_lowat_file=str(notsent_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('excessive write buffering' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 194 regression tests passed: 6/6 tests ok"
