#!/usr/bin/env bash
# tests/fm-jev-syn-retry-guard.test.sh - Regression tests for Pattern 189 (TCP SYN Retry & Retransmission Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-syn-retry-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-syn-retry-guard.py"

echo "Running Pattern 189 regression tests..."

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
assert 'snmp_tcp' in data
assert 'netstat_counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_syn_retries' in s
assert 'tcp_synack_retries' in s
assert 'tcp_retries1' in s
assert 'tcp_retries2' in s
assert 'out_segs' in s
assert 'retrans_segs' in s
assert 'retrans_pct' in s
assert 'syn_retrans' in s
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
mod = import_module('fm-jev-syn-retry-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    syn_f = d / 'tcp_syn_retries'
    synack_f = d / 'tcp_synack_retries'
    retries1_f = d / 'tcp_retries1'
    retries2_f = d / 'tcp_retries2'
    orphan_f = d / 'tcp_orphan_retries'
    snmp_f = d / 'snmp'
    netstat_f = d / 'netstat'

    syn_f.write_text('6\n')
    synack_f.write_text('5\n')
    retries1_f.write_text('3\n')
    retries2_f.write_text('15\n')
    orphan_f.write_text('0\n')

    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 100 100 10 5 20 500000 500000 500 0 10 0
''')

    netstat_f.write_text('''TcpExt: TCPSynRetrans TCPTimeouts TCPSpuriousRTOs TCPRcvCollapsed TCPLostRetransmit TCPRetransFail
TcpExt: 25 10 2 0 1 0
''')

    # Case 1: Nominal
    res = mod.audit_syn_retries(
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        retries1_file=str(retries1_f),
        retries2_file=str(retries2_f),
        orphan_retries_file=str(orphan_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_syn_retries'] == 6
    assert res['summary']['tcp_retries2'] == 15
    assert res['summary']['out_segs'] == 500000
    assert res['summary']['retrans_segs'] == 500
    assert res['summary']['retrans_pct'] == 0.1
    assert res['summary']['syn_retrans'] == 25

    # Case 2: syn_retries == 0 -> CRITICAL
    syn_f.write_text('0\n')
    res2 = mod.audit_syn_retries(
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        retries1_file=str(retries1_f),
        retries2_file=str(retries2_f),
        orphan_retries_file=str(orphan_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('tcp_syn_retries is 0' in iss for iss in res2['summary']['issues'])

    # Case 3: retries2 < 3 -> CRITICAL
    syn_f.write_text('6\n')
    retries2_f.write_text('2\n')
    res3 = mod.audit_syn_retries(
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        retries1_file=str(retries1_f),
        retries2_file=str(retries2_f),
        orphan_retries_file=str(orphan_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('dangerously low' in iss for iss in res3['summary']['issues'])

    # Case 4: High retrans percentage (> 10%) -> CRITICAL
    retries2_f.write_text('15\n')
    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 100 100 10 5 20 500000 100000 12000 0 10 0
''')
    res4 = mod.audit_syn_retries(
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        retries1_file=str(retries1_f),
        retries2_file=str(retries2_f),
        orphan_retries_file=str(orphan_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'CRITICAL'
    assert any('exceeds 10.0%' in iss for iss in res4['summary']['issues'])

    # Case 5: Moderate retrans percentage (>= 3%) -> WARNING
    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 100 100 10 5 20 500000 100000 3500 0 10 0
''')
    res5 = mod.audit_syn_retries(
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        retries1_file=str(retries1_f),
        retries2_file=str(retries2_f),
        orphan_retries_file=str(orphan_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('exceeds 3.0%' in iss for iss in res5['summary']['issues'])

    # Case 6: Excessive SYN retries (> 8) -> WARNING
    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 100 100 10 5 20 500000 100000 100 0 10 0
''')
    syn_f.write_text('10\n')
    res6 = mod.audit_syn_retries(
        syn_retries_file=str(syn_f),
        synack_retries_file=str(synack_f),
        retries1_file=str(retries1_f),
        retries2_file=str(retries2_f),
        orphan_retries_file=str(orphan_f),
        snmp_file=str(snmp_f),
        netstat_file=str(netstat_f),
    )
    assert res6['summary']['status'] == 'WARNING'
    assert any('tcp_syn_retries (10) > 8' in iss for iss in res6['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 189 regression tests passed: 6/6 tests ok"
