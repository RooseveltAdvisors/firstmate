#!/usr/bin/env bash
# tests/fm-jev-syn-scramble-guard.test.sh - Regression tests for Pattern 125 (TCP SYN/FIN Scrambling Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-syn-scramble-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-syn-scramble-guard.py"

echo "Running Pattern 125 regression tests..."

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
assert 'rfc1337' in s
assert 'timestamps' in s
assert 'abort_on_overflow' in s
assert 'estab_resets' in s
assert 'attempt_fails' in s
assert 'out_rsts' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and procfs files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-syn-scramble-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    rfc1337_f = d / 'tcp_rfc1337'
    timestamps_f = d / 'tcp_timestamps'
    abort_ovf_f = d / 'tcp_abort_on_overflow'
    syn_f = d / 'tcp_syn_retries'
    synack_f = d / 'tcp_synack_retries'
    snmp_f = d / 'snmp'
    netstat_f = d / 'netstat'

    rfc1337_f.write_text('0\n')
    timestamps_f.write_text('1\n')
    abort_ovf_f.write_text('0\n')
    syn_f.write_text('6\n')
    synack_f.write_text('5\n')

    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 50000 40000 100 200 15 1000000 900000 50 2 300 0
''')

    netstat_f.write_text('''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed EmbryonicRsts PruneCalled RcvPruned OfoPruned OutOfWindowIcmds LockDroppedIcmds ArpFilter TW TWRecycled TWKilled PAWSPassive PAWSActive PAWSEstab DelayedACKs DelayedACKLocked DelayedACKLost ListenOverflows ListenDrops TCPHPHits TCPAllocFails TCPTimeWaitOverflow TCPTLSKey TCPAbortOnData TCPAbortOnClose TCPAbortOnMemory TCPAbortOnTimeout TCPAbortFailed TCPMemoryPressures
TcpExt: 0 0 0 10 0 0 0 0 0 0 100 0 0 0 0 0 500 0 0 0 0 2000 0 0 0 50 10 0 5 2 0
''')

    # Case 1: Nominal
    res = mod.audit_syn_scramble(
        rfc1337_file=str(rfc1337_f),
        timestamps_file=str(timestamps_f),
        abort_overflow_file=str(abort_ovf_f),
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['timestamps'] == 1
    assert res['summary']['abort_on_overflow'] == 0
    assert res['counters']['estab_resets'] == 200
    assert res['counters']['embryonic_rsts'] == 10

    # Case 2: Timestamps disabled (PAWS off) -> WARNING
    timestamps_f.write_text('0\n')
    res2 = mod.audit_syn_scramble(
        rfc1337_file=str(rfc1337_f),
        timestamps_file=str(timestamps_f),
        abort_overflow_file=str(abort_ovf_f),
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_timestamps = 0' in iss for iss in res2['summary']['issues'])
    timestamps_f.write_text('1\n')

    # Case 3: Memory abort pressure -> WARNING
    bad_netstat = '''TcpExt: SyncookiesSent EmbryonicRsts TCPAbortOnMemory TCPAbortFailed
TcpExt: 0 5 12 0
'''
    netstat_f.write_text(bad_netstat)
    res3 = mod.audit_syn_scramble(
        rfc1337_file=str(rfc1337_f),
        timestamps_file=str(timestamps_f),
        abort_overflow_file=str(abort_ovf_f),
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('TCPAbortOnMemory' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 125 regression tests passed!"
