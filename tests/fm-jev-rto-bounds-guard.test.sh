#!/usr/bin/env bash
# tests/fm-jev-rto-bounds-guard.test.sh - Regression tests for Pattern 170 (TCP RTO Bounds Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rto-bounds-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rto-bounds-guard.py"

echo "Running Pattern 170 regression tests..."

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
assert 'tcp_rto_min_us' in s
assert 'tcp_rto_max_ms' in s
assert 'timeouts' in s
assert 'spurious_rtos' in s
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
mod = import_module('fm-jev-rto-bounds-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    rto_min_f = d / 'tcp_rto_min_us'
    rto_max_f = d / 'tcp_rto_max_ms'
    netstat_f = d / 'netstat'

    rto_min_f.write_text('200000\n')
    rto_max_f.write_text('120000\n')
    netstat_f.write_text('''TcpExt: TCPTimeouts TCPSpuriousRTOs TCPLossProbes TCPLossProbeRecovery
TcpExt: 700000 800 1000000 20000
''')

    # Case 1: Nominal
    res = mod.audit_rto_bounds(
        rto_min_us_file=str(rto_min_f),
        rto_max_ms_file=str(rto_max_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_rto_min_us'] == 200000
    assert res['summary']['tcp_rto_max_ms'] == 120000
    assert res['summary']['spurious_rtos'] == 800

    # Case 2: Dangerously low rto_min -> WARNING
    rto_min_f.write_text('20000\n')
    res2 = mod.audit_rto_bounds(
        rto_min_us_file=str(rto_min_f),
        rto_max_ms_file=str(rto_max_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Dangerously low tcp_rto_min_us' in iss for iss in res2['summary']['issues'])

    # Case 3: High spurious RTO ratio -> WARNING
    rto_min_f.write_text('200000\n')
    netstat_f.write_text('''TcpExt: TCPTimeouts TCPSpuriousRTOs TCPLossProbes TCPLossProbeRecovery
TcpExt: 1000 100 1000000 20000
''')
    res3 = mod.audit_rto_bounds(
        rto_min_us_file=str(rto_min_f),
        rto_max_ms_file=str(rto_max_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('spurious RTO ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 170 regression tests passed!"
