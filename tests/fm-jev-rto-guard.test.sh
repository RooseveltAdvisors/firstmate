#!/usr/bin/env bash
# tests/fm-jev-rto-guard.test.sh - Regression tests for Pattern 111 (TCP RACK/TLP Loss Recovery Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rto-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rto-guard.py"

echo "Running Pattern 111 regression tests..."

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
assert 'rack_loss_detection' in s
assert 'tail_loss_probe_tlp' in s
assert 'tcp_frto_mode' in s
assert 'timeouts_count' in s
assert 'spurious_rto_pct' in s
assert 'tlp_recovery_pct' in s
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
mod = import_module('fm-jev-rto-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    recovery_file = d / 'tcp_recovery'
    frto_file = d / 'tcp_frto'
    retries1_file = d / 'tcp_retries1'
    retries2_file = d / 'tcp_retries2'
    netstat_file = d / 'netstat'

    recovery_file.write_text('3\n') # RACK (1) + TLP (2)
    frto_file.write_text('2\n')
    retries1_file.write_text('3\n')
    retries2_file.write_text('15\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPTimeouts TCPLossProbes TCPLossProbeRecovery TCPSpuriousRTOs TCPLostRetransmit TCPFastRetrans TCPSlowStartRetrans TCPSackRecoveryFail
TcpExt: 0 100 200 50 5 10 300 20 2
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_rto(
        recovery_file=str(recovery_file),
        frto_file=str(frto_file),
        retries1_file=str(retries1_file),
        retries2_file=str(retries2_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['rack_loss_detection'] is True
    assert res['summary']['tail_loss_probe_tlp'] is True
    assert res['summary']['tlp_recovery_pct'] == 25.0
    assert res['summary']['spurious_rto_pct'] == 5.0

    # Case 2: High retries2 warning
    retries2_file.write_text('20\n')
    res2 = mod.audit_rto(
        recovery_file=str(recovery_file),
        frto_file=str(frto_file),
        retries1_file=str(retries1_file),
        retries2_file=str(retries2_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('High tcp_retries2' in iss for iss in res2['summary']['issues'])
    retries2_file.write_text('15\n')

    # Case 3: High spurious RTO warning
    spurious_netstat = mock_netstat.replace(' 0 100 200 50 5 10 300 20 2', ' 0 100 200 50 40 10 300 20 2')
    netstat_file.write_text(spurious_netstat)
    res3 = mod.audit_rto(
        recovery_file=str(recovery_file),
        frto_file=str(frto_file),
        retries1_file=str(retries1_file),
        retries2_file=str(retries2_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('High spurious RTO rate' in iss for iss in res3['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 111 tests passed successfully!"
