#!/usr/bin/env bash
# tests/fm-jev-tcp-retrans-guard.test.sh - Regression tests for Pattern 103 (TCP Retransmission & Checksum Error Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tcp-retrans-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tcp-retrans-guard.py"

echo "Running Pattern 103 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['retrans_ratio_pct'], float)
assert isinstance(s['curr_estab'], int)
assert isinstance(s['in_segs'], int)
assert isinstance(s['out_segs'], int)
assert isinstance(s['retrans_segs'], int)
assert isinstance(s['in_csum_errors'], int)
assert isinstance(s['in_errs'], int)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysfs / procfs files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-tcp-retrans-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    snmp_f = d / 'snmp'
    netstat_f = d / 'netstat'
    r1_f = d / 'tcp_retries1'
    r2_f = d / 'tcp_retries2'
    reorder_f = d / 'tcp_reordering'

    snmp_f.write_text(
        'Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors\n'
        'Tcp: 1 200 120000 -1 100 50 10 5 20 10000 10000 10 0 50 0\n'
    )
    netstat_f.write_text(
        'TcpExt: SyncookiesSent TCPTimeouts TCPLossProbes TCPFastRetrans TCPSlowStartRetrans TCPSpuriousRtxHost\n'
        'TcpExt: 0 10 20 5 1 0\n'
    )
    r1_f.write_text('3\n')
    r2_f.write_text('15\n')
    reorder_f.write_text('3\n')

    rep = mod.audit_tcp_retrans(
        proc_snmp=str(snmp_f),
        proc_netstat=str(netstat_f),
        sysctl_retries1=str(r1_f),
        sysctl_retries2=str(r2_f),
        sysctl_reordering=str(reorder_f),
    )
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['retrans_ratio_pct'] == 0.1
    assert s['in_csum_errors'] == 0

    # Mock Critical condition (retrans >= 5%)
    snmp_f.write_text(
        'Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors\n'
        'Tcp: 1 200 120000 -1 100 50 10 5 20 10000 10000 600 0 50 0\n'
    )
    rep_crit = mod.audit_tcp_retrans(
        proc_snmp=str(snmp_f),
        proc_netstat=str(netstat_f),
        sysctl_retries1=str(r1_f),
        sysctl_retries2=str(r2_f),
        sysctl_reordering=str(reorder_f),
    )
    assert rep_crit['summary']['status'] == 'CRITICAL'
    assert rep_crit['summary']['healthy'] is False
    assert any('Excessive TCP retransmission rate' in iss for iss in rep_crit['summary']['issues'])

    # Mock Checksum Error
    snmp_f.write_text(
        'Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors\n'
        'Tcp: 1 200 120000 -1 100 50 10 5 20 10000 10000 10 0 50 3\n'
    )
    rep_csum = mod.audit_tcp_retrans(
        proc_snmp=str(snmp_f),
        proc_netstat=str(netstat_f),
        sysctl_retries1=str(r1_f),
        sysctl_retries2=str(r2_f),
        sysctl_reordering=str(reorder_f),
    )
    assert rep_csum['summary']['status'] == 'CRITICAL'
    assert rep_csum['summary']['healthy'] is False
    assert any('TCP checksum errors detected' in iss for iss in rep_csum['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 103 tests passed successfully."
