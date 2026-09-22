#!/usr/bin/env bash
# tests/fm-jev-finwait-guard.test.sh - Regression tests for Pattern 108 (TCP FIN-WAIT-2 Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-finwait-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-finwait-guard.py"

echo "Running Pattern 108 regression tests..."

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
assert 'states' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_fin_timeout_sec' in s
assert 'tcp_max_orphans' in s
assert 'orphan_sockets' in s
assert 'fin_wait2_sockets' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/ files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-finwait-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    fin_file = d / 'tcp_fin_timeout'
    orphans_file = d / 'tcp_max_orphans'
    sockstat_file = d / 'sockstat'
    tcp_file = d / 'tcp'
    tcp6_file = d / 'tcp6'

    fin_file.write_text('60\n')
    orphans_file.write_text('262144\n')

    mock_sockstat = '''sockets: used 500
TCP: inuse 100 orphan 5 tw 20 alloc 120 mem 0
'''
    sockstat_file.write_text(mock_sockstat)

    mock_tcp = '''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1539 0100007F:1538 05 00000000:00000000 00:00000000 00000000  1000        0 12346 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1540 0100007F:1538 04 00000000:00000000 00:00000000 00000000  1000        0 12347 1 0000000000000000 100 0 0 10 0
'''
    tcp_file.write_text(mock_tcp)
    tcp6_file.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n')

    # Case 1: Nominal
    res = mod.audit_finwait(
        fin_timeout_file=str(fin_file),
        max_orphans_file=str(orphans_file),
        sockstat_file=str(sockstat_file),
        tcp_file=str(tcp_file),
        tcp6_file=str(tcp6_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_fin_timeout_sec'] == 60
    assert res['summary']['orphan_sockets'] == 5
    assert res['summary']['fin_wait2_sockets'] == 1
    assert res['states']['fin_wait1'] == 1

    # Case 2: Excessive FIN timeout warning
    fin_file.write_text('120\n')
    res2 = mod.audit_finwait(
        fin_timeout_file=str(fin_file),
        max_orphans_file=str(orphans_file),
        sockstat_file=str(sockstat_file),
        tcp_file=str(tcp_file),
        tcp6_file=str(tcp6_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('High tcp_fin_timeout' in iss for iss in res2['summary']['issues'])
    fin_file.write_text('60\n')

    # Case 3: High orphan socket warning
    bad_sockstat = '''sockets: used 500
TCP: inuse 100 orphan 2000 tw 20 alloc 120 mem 0
'''
    sockstat_file.write_text(bad_sockstat)
    res3 = mod.audit_finwait(
        fin_timeout_file=str(fin_file),
        max_orphans_file=str(orphans_file),
        sockstat_file=str(sockstat_file),
        tcp_file=str(tcp_file),
        tcp6_file=str(tcp6_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('High orphan TCP sockets' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 108 tests passed!"
