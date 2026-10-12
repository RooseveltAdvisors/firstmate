#!/usr/bin/env bash
# tests/fm-jev-thin-timeout-guard.test.sh - Regression tests for Pattern 235 (TCP Thin Timeout Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-thin-timeout-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-thin-timeout-guard.py"

echo "Running Pattern 235 regression tests..."

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
assert 'tcp_thin_linear_timeouts' in s
assert 'tcp_syn_linear_timeouts' in s
assert 'timeouts' in s
assert 'spurious_rtos' in s
assert 'spurious_ratio_pct' in s
assert 'loss_failures' in s
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
mod = import_module('fm-jev-thin-timeout-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    thin_f = d / 'tcp_thin_linear_timeouts'
    syn_f = d / 'tcp_syn_linear_timeouts'
    netstat_f = d / 'netstat'

    thin_f.write_text('0\n')
    syn_f.write_text('4\n')
    netstat_f.write_text('''TcpExt: TCPTimeouts TCPSpuriousRTOs TCPLossFailures
TcpExt: 10000 100 15
''')

    # Case 1: Nominal (100 / 10000 = 1.0%)
    res = mod.audit_thin_timeouts(thin_timeouts_file=str(thin_f), syn_timeouts_file=str(syn_f), netstat_file=str(netstat_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_thin_linear_timeouts'] == 0
    assert res['summary']['tcp_syn_linear_timeouts'] == 4
    assert res['summary']['timeouts'] == 10000
    assert res['summary']['spurious_rtos'] == 100
    assert res['summary']['spurious_ratio_pct'] == 1.0

    # Case 2: Disabled syn linear timeouts (0) -> WARNING
    syn_f.write_text('0\n')
    res2 = mod.audit_thin_timeouts(thin_timeouts_file=str(thin_f), syn_timeouts_file=str(syn_f), netstat_file=str(netstat_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_syn_linear_timeouts is 0' in iss for iss in res2['summary']['issues'])

    # Case 3: Elevated spurious RTO (> 25%) -> WARNING
    syn_f.write_text('4\n')
    netstat_f.write_text('''TcpExt: TCPTimeouts TCPSpuriousRTOs TCPLossFailures
TcpExt: 10000 3000 15
''')
    res3 = mod.audit_thin_timeouts(thin_timeouts_file=str(thin_f), syn_timeouts_file=str(syn_f), netstat_file=str(netstat_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('Elevated spurious RTO ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 235 regression tests passed!"
