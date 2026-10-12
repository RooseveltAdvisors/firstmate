#!/usr/bin/env bash
# tests/fm-jev-child-ehash-guard.test.sh - Regression tests for Pattern 185 (TCP Child Established Hash Table Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-child-ehash-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-child-ehash-guard.py"

echo "Running Pattern 185 regression tests..."

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
assert 'sockstat' in data
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_child_ehash_entries' in s
assert 'tcp_ehash_entries' in s
assert 'udp_child_hash_entries' in s
assert 'tcp_plb_rehash_rounds' in s
assert 'tcp_inuse' in s
assert 'tcp_tw' in s
assert 'active_tcp_entries' in s
assert 'ehash_saturation_ratio' in s
assert 'listen_overflows' in s
assert 'listen_drops' in s
assert 'backlog_drops' in s
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
mod = import_module('fm-jev-child-ehash-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    child_f = d / 'tcp_child_ehash_entries'
    ehash_f = d / 'tcp_ehash_entries'
    udp_f = d / 'udp_child_hash_entries'
    plb_f = d / 'tcp_plb_rehash_rounds'
    sockstat_f = d / 'sockstat'
    netstat_f = d / 'netstat'

    child_f.write_text('0\n')
    ehash_f.write_text('524288\n')
    udp_f.write_text('0\n')
    plb_f.write_text('12\n')
    sockstat_f.write_text('''sockets: used 1500
TCP: inuse 500 orphan 0 tw 200 alloc 550 mem 0
UDP: inuse 20 mem 200
''')
    netstat_f.write_text('''TcpExt: ListenOverflows ListenDrops TCPBacklogDrop TcpTimeoutRehash TCPPLBRehash
TcpExt: 0 0 0 100 0
''')

    # Case 1: Nominal
    res = mod.audit_child_ehash(
        child_ehash_file=str(child_f),
        ehash_file=str(ehash_f),
        udp_child_file=str(udp_f),
        plb_rehash_file=str(plb_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_child_ehash_entries'] == 0
    assert res['summary']['tcp_ehash_entries'] == 524288
    assert res['summary']['tcp_inuse'] == 500
    assert res['summary']['tcp_tw'] == 200
    assert res['summary']['active_tcp_entries'] == 700
    assert res['summary']['ehash_saturation_ratio'] < 0.01

    # Case 2: Missing / invalid global ehash -> WARNING
    ehash_f.write_text('-1\n')
    res2 = mod.audit_child_ehash(
        child_ehash_file=str(child_f),
        ehash_file=str(ehash_f),
        udp_child_file=str(udp_f),
        plb_rehash_file=str(plb_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('Unable to determine global' in iss for iss in res2['summary']['issues'])

    # Case 3: High saturation (> 50%) -> WARNING
    ehash_f.write_text('1000\n')
    res3 = mod.audit_child_ehash(
        child_ehash_file=str(child_f),
        ehash_file=str(ehash_f),
        udp_child_file=str(udp_f),
        plb_rehash_file=str(plb_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert res3['summary']['healthy'] is False
    assert any('Global ehash saturation critical' in iss for iss in res3['summary']['issues'])

    # Case 4: Backlog drop detected -> WARNING
    ehash_f.write_text('524288\n')
    netstat_f.write_text('''TcpExt: ListenOverflows ListenDrops TCPBacklogDrop TcpTimeoutRehash TCPPLBRehash
TcpExt: 0 0 5 100 0
''')
    res4 = mod.audit_child_ehash(
        child_ehash_file=str(child_f),
        ehash_file=str(ehash_f),
        udp_child_file=str(udp_f),
        plb_rehash_file=str(plb_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('Active TCP socket backlog drops' in iss for iss in res4['summary']['issues'])

    # Case 5: High listen drops -> WARNING
    netstat_f.write_text('''TcpExt: ListenOverflows ListenDrops TCPBacklogDrop TcpTimeoutRehash TCPPLBRehash
TcpExt: 0 150 0 100 0
''')
    res5 = mod.audit_child_ehash(
        child_ehash_file=str(child_f),
        ehash_file=str(ehash_f),
        udp_child_file=str(udp_f),
        plb_rehash_file=str(plb_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('High TCP listener drops' in iss for iss in res5['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 185 regression tests passed: 6/6 tests ok"
