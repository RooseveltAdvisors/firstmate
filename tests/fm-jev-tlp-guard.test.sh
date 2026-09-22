#!/usr/bin/env bash
# tests/fm-jev-tlp-guard.test.sh - Regression tests for Pattern 154 (TCP TLP Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tlp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tlp-guard.py"

echo "Running Pattern 154 regression tests..."

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
assert 'tcp_early_retrans' in s
assert 'loss_probes' in s
assert 'loss_probe_recovery' in s
assert 'recovery_ratio_pct' in s
assert 'loss_failures' in s
assert 'failure_ratio_pct' in s
assert 'loss_undo' in s
assert 'fast_retrans' in s
assert 'timeouts' in s
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
mod = import_module('fm-jev-tlp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sysctl_f = d / 'tcp_early_retrans'
    netstat_f = d / 'netstat'

    sysctl_f.write_text('3\n')
    netstat_f.write_text('''TcpExt: TCPLossProbes TCPLossProbeRecovery TCPLossFailures TCPLossUndo TCPFastRetrans TCPTimeouts
TcpExt: 10000 500 20 150 2000 5000
''')

    # Case 1: Nominal (500 recovered / 10000 = 5.0%, 20 fail / 10000 = 0.2%)
    res = mod.audit_tlp(sysctl_file=str(sysctl_f), netstat_file=str(netstat_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_early_retrans'] == 3
    assert res['summary']['loss_probes'] == 10000
    assert res['summary']['loss_probe_recovery'] == 500
    assert res['summary']['recovery_ratio_pct'] == 5.0
    assert res['summary']['loss_failures'] == 20
    assert res['summary']['failure_ratio_pct'] == 0.2

    # Case 2: Disabled sysctl (0) -> WARNING
    sysctl_f.write_text('0\n')
    res2 = mod.audit_tlp(sysctl_file=str(sysctl_f), netstat_file=str(netstat_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_early_retrans is disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Excessive loss probe failures (> 50%) -> WARNING
    sysctl_f.write_text('3\n')
    netstat_f.write_text('''TcpExt: TCPLossProbes TCPLossProbeRecovery TCPLossFailures TCPLossUndo TCPFastRetrans TCPTimeouts
TcpExt: 10000 500 6000 150 2000 5000
''')
    res3 = mod.audit_tlp(sysctl_file=str(sysctl_f), netstat_file=str(netstat_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('High loss probe failure ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 154 regression tests passed!"
