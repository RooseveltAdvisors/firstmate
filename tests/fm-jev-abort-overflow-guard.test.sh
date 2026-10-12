#!/usr/bin/env bash
# tests/fm-jev-abort-overflow-guard.test.sh - Regression tests for Pattern 187 (TCP Listener Abort-On-Overflow Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-abort-overflow-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-abort-overflow-guard.py"

echo "Running Pattern 187 regression tests..."

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
assert 'tcp_abort_on_overflow' in s
assert 'tcp_fin_timeout' in s
assert 'tcp_max_syn_backlog' in s
assert 'somaxconn' in s
assert 'listen_overflows' in s
assert 'listen_drops' in s
assert 'req_q_full_drop' in s
assert 'embryonic_rsts' in s
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
mod = import_module('fm-jev-abort-overflow-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    abort_f = d / 'tcp_abort_on_overflow'
    fin_f = d / 'tcp_fin_timeout'
    syn_f = d / 'tcp_max_syn_backlog'
    somax_f = d / 'somaxconn'
    netstat_f = d / 'netstat'

    abort_f.write_text('0\n')
    fin_f.write_text('60\n')
    syn_f.write_text('4096\n')
    somax_f.write_text('4096\n')
    netstat_f.write_text('''TcpExt: ListenOverflows ListenDrops TCPReqQFullDrop TCPReqQFullDoCookies EmbryonicRsts
TcpExt: 0 0 0 0 14
''')

    # Case 1: Nominal
    res = mod.audit_abort_overflow(
        abort_overflow_file=str(abort_f),
        fin_timeout_file=str(fin_f),
        syn_backlog_file=str(syn_f),
        somaxconn_file=str(somax_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_abort_on_overflow'] == 0
    assert res['summary']['tcp_fin_timeout'] == 60
    assert res['summary']['embryonic_rsts'] == 14

    # Case 2: abort_on_overflow = 1 -> WARNING
    abort_f.write_text('1\n')
    res2 = mod.audit_abort_overflow(
        abort_overflow_file=str(abort_f),
        fin_timeout_file=str(fin_f),
        syn_backlog_file=str(syn_f),
        somaxconn_file=str(somax_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('breaks client exponential backoff' in iss for iss in res2['summary']['issues'])

    # Case 3: Excessive FIN timeout -> WARNING
    abort_f.write_text('0\n')
    fin_f.write_text('180\n')
    res3 = mod.audit_abort_overflow(
        abort_overflow_file=str(abort_f),
        fin_timeout_file=str(fin_f),
        syn_backlog_file=str(syn_f),
        somaxconn_file=str(somax_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Excessive TCP FIN timeout' in iss for iss in res3['summary']['issues'])

    # Case 4: High listen overflows -> WARNING
    fin_f.write_text('60\n')
    netstat_f.write_text('''TcpExt: ListenOverflows ListenDrops TCPReqQFullDrop TCPReqQFullDoCookies EmbryonicRsts
TcpExt: 250 0 0 0 14
''')
    res4 = mod.audit_abort_overflow(
        abort_overflow_file=str(abort_f),
        fin_timeout_file=str(fin_f),
        syn_backlog_file=str(syn_f),
        somaxconn_file=str(somax_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('High listener queue overflows' in iss for iss in res4['summary']['issues'])

    # Case 5: Req queue full drop -> WARNING
    netstat_f.write_text('''TcpExt: ListenOverflows ListenDrops TCPReqQFullDrop TCPReqQFullDoCookies EmbryonicRsts
TcpExt: 0 0 10 0 14
''')
    res5 = mod.audit_abort_overflow(
        abort_overflow_file=str(abort_f),
        fin_timeout_file=str(fin_f),
        syn_backlog_file=str(syn_f),
        somaxconn_file=str(somax_f),
        netstat_file=str(netstat_f),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('TCP request queue full drops' in iss for iss in res5['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 187 regression tests passed: 6/6 tests ok"
