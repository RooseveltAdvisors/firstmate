#!/usr/bin/env bash
# tests/fm-jev-sack-reneging-guard.test.sh - Regression tests for Pattern 152 (TCP SACK Reneging Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sack-reneging-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sack-reneging-guard.py"

echo "Running Pattern 152 regression tests..."

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
assert 'sack_reneging' in s
assert 'sack_recovery' in s
assert 'sack_recovery_fail' in s
assert 'recovery_fail_ratio_pct' in s
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
mod = import_module('fm-jev-sack-reneging-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'

    netstat_f.write_text('''TcpExt: TCPSackRecovery TCPSACKReneging TCPSackFailures TCPSackRecoveryFail TCPSACKDiscard TCPSackShifted TCPSackMerged
TcpExt: 1000 2 10 50 100 200 300
''')

    # Case 1: Nominal (50 fail / 1000 total = 5.0%)
    res = mod.audit_sack_reneging(netstat_file=str(netstat_f))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['sack_reneging'] == 2
    assert res['summary']['sack_recovery'] == 1000
    assert res['summary']['recovery_fail_ratio_pct'] == 5.0

    # Case 2: Elevated SACK reneging (> 100) -> WARNING
    netstat_f.write_text('''TcpExt: TCPSackRecovery TCPSACKReneging TCPSackFailures TCPSackRecoveryFail TCPSACKDiscard TCPSackShifted TCPSackMerged
TcpExt: 1000 150 10 50 100 200 300
''')
    res2 = mod.audit_sack_reneging(netstat_file=str(netstat_f))
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated SACK reneging' in iss for iss in res2['summary']['issues'])

    # Case 3: High failure ratio (> 25%) -> WARNING
    netstat_f.write_text('''TcpExt: TCPSackRecovery TCPSACKReneging TCPSackFailures TCPSackRecoveryFail TCPSACKDiscard TCPSackShifted TCPSackMerged
TcpExt: 1000 2 10 300 100 200 300
''')
    res3 = mod.audit_sack_reneging(netstat_file=str(netstat_f))
    assert res3['summary']['status'] == 'WARNING'
    assert any('High SACK recovery failure ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 152 regression tests passed!"
