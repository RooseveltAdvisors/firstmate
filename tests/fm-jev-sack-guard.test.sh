#!/usr/bin/env bash
# tests/fm-jev-sack-guard.test.sh - Regression tests for Pattern 102 (TCP Window Scale & SACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sack-guard.py"

echo "Running Pattern 102 regression tests..."

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
assert 'tcp_sack_enabled' in s
assert 'tcp_window_scaling_enabled' in s
assert 'tcp_dsack_enabled' in s
assert 'sack_recovery_events' in s
assert 'sack_reneging_events' in s
assert 'sack_failures' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctls and /proc/net/netstat
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-sack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sack_file = d / 'tcp_sack'
    scaling_file = d / 'tcp_window_scaling'
    dsack_file = d / 'tcp_dsack'
    rmem_file = d / 'tcp_rmem'
    wmem_file = d / 'tcp_wmem'
    netstat_file = d / 'netstat'

    sack_file.write_text('1\n')
    scaling_file.write_text('1\n')
    dsack_file.write_text('1\n')
    rmem_file.write_text('4096 131072 6291456\n')
    wmem_file.write_text('4096 16384 4194304\n')

    mock_netstat = '''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts PruneCalled RcvPruned OfoPruned OutOfWindowIcmds LockDroppedIcmds ArpFilter TW TWRecycled TWKilled PAWSPassive PAWSActive PAWSEstabl DelayedACKs DelayedACKLocked DelayedACKLost ListenOverflows ListenDrops TCPSACKReneging TCPReordering TCPSACKReorder TCPSlowStartRetrans TCPFastRetrans TCPSackRecovery TCPSackFailures TCPAutoMetric TCPAbortOnSyn TCPAbortOnData TCPAbortOnClose TCPAbortOnMemory TCPAbortOnTimeout TCPAbortFailed TCPMemoryPressures TCPMemoryPressuresChg TCPSACKDiscard TCPDSACKIgnoredOld TCPDSACKIgnoredNoUndo TCPSpuriousRTOs TCPMD5NotFound TCPMD5Unexpected TCPSackShifted TCPSackMerged TCPSackShiftFallback TCPBacklogDrop PFMemallocDrop TCPMinTTLDrop TCPOFOQueue TCPOFOMerge TCPChallengeACK TCPSYNChallenge TCPSpuriousRtxHost TCPDSACKRecv TCPDSACKOldSent
TcpExt: 0 0 0 0 0 0 0 0 0 0 100 0 0 0 0 0 500 0 0 0 0 0 10 5 0 20 100 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 50 10
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_sack_scaling(
        sack_file=str(sack_file),
        scaling_file=str(scaling_file),
        dsack_file=str(dsack_file),
        rmem_file=str(rmem_file),
        wmem_file=str(wmem_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_sack_enabled'] is True
    assert res['summary']['tcp_window_scaling_enabled'] is True
    assert res['summary']['sack_recovery_events'] == 100
    assert res['summary']['sack_failures'] == 2
    assert res['summary']['sack_reneging_events'] == 0

    # Case 2: Disabled SACK
    sack_file.write_text('0\n')
    res2 = mod.audit_sack_scaling(
        sack_file=str(sack_file),
        scaling_file=str(scaling_file),
        dsack_file=str(dsack_file),
        rmem_file=str(rmem_file),
        wmem_file=str(wmem_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_sack=0' in iss for iss in res2['summary']['issues'])
    sack_file.write_text('1\n')

    # Case 3: Disabled Window Scaling
    scaling_file.write_text('0\n')
    res3 = mod.audit_sack_scaling(
        sack_file=str(sack_file),
        scaling_file=str(scaling_file),
        dsack_file=str(dsack_file),
        rmem_file=str(rmem_file),
        wmem_file=str(wmem_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('tcp_window_scaling=0' in iss for iss in res3['summary']['issues'])
    scaling_file.write_text('1\n')

    # Case 4: SACK reneging
    bad_netstat = mock_netstat.replace(' 0 10 5 0 20 100 2 ', ' 15 10 5 0 20 100 2 ')
    netstat_file.write_text(bad_netstat)
    res4 = mod.audit_sack_scaling(
        sack_file=str(sack_file),
        scaling_file=str(scaling_file),
        dsack_file=str(dsack_file),
        rmem_file=str(rmem_file),
        wmem_file=str(wmem_file),
        netstat_file=str(netstat_file),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('TCP SACK reneging' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 102 tests passed!"
