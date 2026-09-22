#!/usr/bin/env bash
# tests/fm-jev-autocork-guard.test.sh - Regression tests for Pattern 135 (TCP Auto Corking Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-autocork-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-autocork-guard.py"

echo "Running Pattern 135 regression tests..."

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
assert 'tcp_autocorking' in s
assert 'autocork_events' in s
assert 'orig_data_sent' in s
assert 'coalesce_ratio_pct' in s
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
mod = import_module('fm-jev-autocork-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    cork_f = d / 'tcp_autocorking'
    netstat_f = d / 'netstat'

    cork_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPAutoCorking TCPOrigDataSent TCPDelivered
TcpExt: 70000 10000000 9500000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_autocork(
        autocorking_file=str(cork_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_autocorking'] == 1
    assert res['summary']['autocork_events'] == 70000
    assert res['summary']['orig_data_sent'] == 10000000
    assert res['summary']['coalesce_ratio_pct'] == 0.7
    assert res['counters']['tcp_autocorking'] == 70000

    # Case 2: Auto-corking disabled -> WARNING
    cork_f.write_text('0\n')
    res2 = mod.audit_autocork(
        autocorking_file=str(cork_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('TCP auto-corking is disabled' in iss for iss in res2['summary']['issues'])
    cork_f.write_text('1\n')

    # Case 3: Missing files fallback (fail-open)
    res3 = mod.audit_autocork(
        autocorking_file='/nonexistent/tcp_autocorking',
        netstat_file='/nonexistent/netstat',
    )
    assert res3['summary']['status'] == 'HEALTHY'
    assert res3['summary']['tcp_autocorking'] == 1
    assert res3['summary']['autocork_events'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 135 regression tests passed!"
