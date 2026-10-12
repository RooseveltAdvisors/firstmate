#!/usr/bin/env bash
# tests/fm-jev-paws-guard.test.sh - Regression tests for Pattern 142 (TCP PAWS Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-paws-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-paws-guard.py"

echo "Running Pattern 142 regression tests..."

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
assert 'tcp_timestamps' in s
assert 'tcp_rfc1337' in s
assert 'total_paws_drops' in s
assert 'paws_drop_ratio_pct' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-paws-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ts_f = d / 'tcp_timestamps'
    rfc_f = d / 'tcp_rfc1337'
    netstat_f = d / 'netstat'

    ts_f.write_text('1\n')
    rfc_f.write_text('0\n')
    netstat_f.write_text('''TcpExt: PAWSActive PAWSEstab PAWSOldAck PAWSTimewait TSEcrRejected TCPDelivered
TcpExt: 0 4000 400 50 0 1000000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_paws_guard(
        timestamps_file=str(ts_f),
        rfc1337_file=str(rfc_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_timestamps'] == 1
    assert res['summary']['paws_estab'] == 4000
    assert res['summary']['total_paws_drops'] == 4450

    # Case 2: Timestamps disabled -> CRITICAL
    ts_f.write_text('0\n')
    res2 = mod.audit_paws_guard(
        timestamps_file=str(ts_f),
        rfc1337_file=str(rfc_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('TCP timestamps are disabled' in iss for iss in res2['summary']['issues'])
    ts_f.write_text('1\n')

    # Case 3: High PAWS drops -> CRITICAL
    netstat_f.write_text('''TcpExt: PAWSActive PAWSEstab PAWSOldAck PAWSTimewait TSEcrRejected TCPDelivered
TcpExt: 10000 50000 5000 1000 0 10000000
''')
    res3 = mod.audit_paws_guard(
        timestamps_file=str(ts_f),
        rfc1337_file=str(rfc_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('Severe PAWS packet drop ratio' in iss for iss in res3['summary']['issues'])

    # Case 4: High TSEcrRejected -> WARNING
    netstat_f.write_text('''TcpExt: PAWSActive PAWSEstab PAWSOldAck PAWSTimewait TSEcrRejected TCPDelivered
TcpExt: 0 0 0 0 2000 1000000000
''')
    res4 = mod.audit_paws_guard(
        timestamps_file=str(ts_f),
        rfc1337_file=str(rfc_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('echoed timestamp rejections' in iss for iss in res4['summary']['issues'])

    # Case 5: Missing files fallback (fail-open)
    res5 = mod.audit_paws_guard(
        timestamps_file='/nonexistent/ts',
        rfc1337_file='/nonexistent/rfc',
        netstat_file='/nonexistent/netstat',
    )
    assert res5['summary']['status'] == 'HEALTHY'
    assert res5['summary']['tcp_timestamps'] == 1
    assert res5['summary']['total_paws_drops'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 142 regression tests passed!"
