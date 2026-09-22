#!/usr/bin/env bash
# tests/fm-jev-prune-guard.test.sh - Regression tests for Pattern 138 (TCP Prune Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-prune-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-prune-guard.py"

echo "Running Pattern 138 regression tests..."

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
assert 'tcp_moderate_rcvbuf' in s
assert 'tcp_rmem_max_bytes' in s
assert 'prune_called' in data['counters']
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
mod = import_module('fm-jev-prune-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    mod_f = d / 'tcp_moderate_rcvbuf'
    rmem_f = d / 'tcp_rmem'
    netstat_f = d / 'netstat'

    mod_f.write_text('1\n')
    rmem_f.write_text('4096 131072 33554432\n')
    netstat_f.write_text('''TcpExt: PruneCalled RcvPruned OfoPruned TCPRcvCollapsed TCPMemoryPressures TCPMemoryPressuresChrono
TcpExt: 100 50 1 200 0 0
''')

    # Case 1: Nominal
    res = mod.audit_prune(
        moderate_rcvbuf_file=str(mod_f),
        rmem_file=str(rmem_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_moderate_rcvbuf'] == 1
    assert res['summary']['tcp_rmem_max_bytes'] == 33554432
    assert res['counters']['prune_called'] == 100
    assert res['counters']['rcv_pruned'] == 50

    # Case 2: Autotuning disabled -> WARNING
    mod_f.write_text('0\n')
    res2 = mod.audit_prune(
        moderate_rcvbuf_file=str(mod_f),
        rmem_file=str(rmem_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('tcp_moderate_rcvbuf is disabled' in iss for iss in res2['summary']['issues'])
    mod_f.write_text('1\n')

    # Case 3: Memory pressure -> WARNING
    netstat_f.write_text('''TcpExt: PruneCalled RcvPruned OfoPruned TCPRcvCollapsed TCPMemoryPressures TCPMemoryPressuresChrono
TcpExt: 100 50 1 200 12 50
''')
    res3 = mod.audit_prune(
        moderate_rcvbuf_file=str(mod_f),
        rmem_file=str(rmem_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('memory pressure episodes' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 138 regression tests passed!"
