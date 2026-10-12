#!/usr/bin/env bash
# tests/fm-jev-udplite-guard.test.sh - Regression tests for Pattern 244 (UdpliteGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-udplite-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-udplite-guard.py"

echo "Running Pattern 244 regression tests..."

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
assert isinstance(s['total_active_sockets'], int)
assert isinstance(s['in_datagrams'], int)
assert isinstance(s['out_datagrams'], int)
assert isinstance(s['rcvbuf_errors'], int)
assert isinstance(s['sndbuf_errors'], int)
assert isinstance(s['in_csum_errors'], int)
assert isinstance(s['mem_errors'], int)
assert isinstance(s['issues'], list)
assert 'details' in data
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-udplite-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    snmp_f = d / 'snmp'
    snmp6_f = d / 'snmp6'
    udplite_f = d / 'udplite'
    udplite6_f = d / 'udplite6'

    snmp_f.write_text('''
UdpLite: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors
UdpLite: 100 0 0 100 0 0 0 0 0
''')

    snmp6_f.write_text('''
UdpLite6InDatagrams 50
UdpLite6NoPorts 0
UdpLite6InErrors 0
UdpLite6OutDatagrams 50
UdpLite6RcvbufErrors 0
UdpLite6SndbufErrors 0
UdpLite6InCsumErrors 0
UdpLite6MemErrors 0
''')

    udplite_f.write_text('''
   sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
    1: 00000000:0035 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 12345 2 0000000000000000 0
''')
    udplite6_f.write_text('  sl  local_address remote_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode ref pointer drops\n')

    rep = mod.audit_udplite(
        snmp_path=str(snmp_f),
        snmp6_path=str(snmp6_f),
        udplite_path=str(udplite_f),
        udplite6_path=str(udplite6_f),
    )
    assert rep['summary']['status'] == 'HEALTHY'
    assert rep['summary']['healthy'] is True
    assert rep['summary']['total_active_sockets'] == 1
    assert rep['summary']['in_datagrams'] == 150
    assert len(rep['summary']['issues']) == 0

    # Receive buffer overflow warning
    snmp_f.write_text('''
UdpLite: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti MemErrors
UdpLite: 100 0 0 100 150 0 0 0 0
''')
    rep = mod.audit_udplite(
        snmp_path=str(snmp_f),
        snmp6_path=str(snmp6_f),
        udplite_path=str(udplite_f),
        udplite6_path=str(udplite6_f),
    )
    assert rep['summary']['status'] == 'WARNING'
    assert rep['summary']['healthy'] is False
    assert any('Elevated UDP-Lite receive buffer overflow drops' in iss for iss in rep['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 244 regression tests passed successfully!"
