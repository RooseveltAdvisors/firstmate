#!/usr/bin/env bash
# tests/fm-jev-finwait-guard.test.sh - Regression tests for Pattern 149 (TCP FIN-WAIT-2 Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-finwait-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-finwait-guard.py"

echo "Running Pattern 149 regression tests..."

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
assert 'sockstat' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_fin_timeout_sec' in s
assert 'tcp_max_orphans' in s
assert 'orphan_count' in s
assert 'fin_wait2_sockets' in s
assert 'close_wait_sockets' in s
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
mod = import_module('fm-jev-finwait-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    tcp_f = d / 'tcp'
    tcp6_f = d / 'tcp6'
    sockstat_f = d / 'sockstat'
    timeout_f = d / 'timeout'
    orphans_f = d / 'orphans'

    timeout_f.write_text('60\n')
    orphans_f.write_text('1000\n')
    sockstat_f.write_text('''sockets: used 500
TCP: inuse 100 orphan 10 tw 50 alloc 120 mem 0
''')
    tcp6_f.write_text('  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n')
    tcp_f.write_text('''  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:7A69 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 776589420 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F90 0100007F:8A34 05 00000000:00000000 00:00000000 00000000  1000        0 776589421 1 0000000000000000 100 0 0 10 0
''')

    # Case 1: Nominal
    res = mod.audit_finwait(
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        sockstat_file=str(sockstat_f),
        fin_timeout_file=str(timeout_f),
        max_orphans_file=str(orphans_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['fin_wait2_sockets'] == 1
    assert res['summary']['orphan_count'] == 10
    assert res['summary']['orphan_util_pct'] == 1.0

    # Case 2: Excessive timeout (> 120s) -> WARNING
    timeout_f.write_text('180\n')
    res2 = mod.audit_finwait(
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        sockstat_file=str(sockstat_f),
        fin_timeout_file=str(timeout_f),
        max_orphans_file=str(orphans_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Excessive tcp_fin_timeout' in iss for iss in res2['summary']['issues'])

    # Case 3: High orphan utilization (> 50%) -> WARNING
    timeout_f.write_text('60\n')
    sockstat_f.write_text('''sockets: used 500
TCP: inuse 100 orphan 600 tw 50 alloc 120 mem 0
''')
    res3 = mod.audit_finwait(
        tcp_file=str(tcp_f),
        tcp6_file=str(tcp6_f),
        sockstat_file=str(sockstat_f),
        fin_timeout_file=str(timeout_f),
        max_orphans_file=str(orphans_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('High orphan socket saturation' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 149 regression tests passed!"
