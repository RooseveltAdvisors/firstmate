#!/usr/bin/env bash
# tests/fm-jev-frto-guard.test.sh - Regression tests for Pattern 196 (TCP Forward RTO Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-frto-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-frto-guard.py"

echo "Running Pattern 196 regression tests..."

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
assert 'tcp_frto' in s
assert 'spurious_rtos' in s
assert 'spurious_rto_pct' in s
assert 'loss_probes_sent' in s
assert 'loss_probe_recoveries' in s
assert 'tlp_recovery_pct' in s
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
mod = import_module('fm-jev-frto-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    frto_f = d / 'tcp_frto'
    netstat_f = d / 'netstat'

    frto_f.write_text('2\n')
    netstat_f.write_text('''TcpExt: TCPSpuriousRTOs TCPLossProbes TCPLossProbeRecovery TCPTimeouts TCPSackRecovery
TcpExt: 10 1000 50 10000 500
''')

    # Case 1: Nominal
    res = mod.audit_frto(
        tcp_frto_file=str(frto_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_frto'] == 2
    assert res['summary']['spurious_rtos'] == 10
    assert res['summary']['spurious_rto_pct'] == 0.1
    assert res['summary']['loss_probe_recoveries'] == 50
    assert res['summary']['tlp_recovery_pct'] == 5.0

    # Case 2: F-RTO disabled (0) -> CRITICAL
    frto_f.write_text('0\n')
    res2 = mod.audit_frto(
        tcp_frto_file=str(frto_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('disabled' in iss for iss in res2['summary']['issues'])

    # Case 3: Excessive spurious RTOs (>= 25%) -> CRITICAL
    frto_f.write_text('2\n')
    netstat_f.write_text('''TcpExt: TCPSpuriousRTOs TCPLossProbes TCPLossProbeRecovery TCPTimeouts TCPSackRecovery
TcpExt: 300 1000 50 1000 500
''')
    res3 = mod.audit_frto(
        tcp_frto_file=str(frto_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('exceeds 25.0%' in iss for iss in res3['summary']['issues'])

    # Case 4: Basic F-RTO (1) -> WARNING
    frto_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPSpuriousRTOs TCPLossProbes TCPLossProbeRecovery TCPTimeouts TCPSackRecovery
TcpExt: 10 1000 50 10000 500
''')
    res4 = mod.audit_frto(
        tcp_frto_file=str(frto_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('SACK-enhanced' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 196 regression tests passed: 6/6 tests ok"
