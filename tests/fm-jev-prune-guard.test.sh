#!/usr/bin/env bash
# tests/fm-jev-prune-guard.test.sh - Regression tests for Pattern 138 (TCP Receive Queue Pruning Guard)
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
assert 'tcp_rmem_max' in s
assert 'prune_called' in s
assert 'rcv_pruned' in s
assert 'tcp_rcv_collapsed' in s
assert 'tcp_memory_pressures' in s
assert 'collapse_ratio_pct' in s
assert 'prune_ratio_pct' in s
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
    rmem_f = d / 'tcp_rmem'
    mem_f = d / 'tcp_mem'
    mod_f = d / 'tcp_moderate_rcvbuf'
    netstat_f = d / 'netstat'

    rmem_f.write_text('4096 131072 33554432\n')
    mem_f.write_text('762738 1016987 1525476\n')
    mod_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: PruneCalled RcvPruned OfoPruned TCPMemoryPressures TCPRcvCollapsed TCPRcvQDrop TCPZeroWindowDrop TCPDelivered
TcpExt: 100 50 1 0 4000 50 0 1000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_prune_guard(
        rmem_file=str(rmem_f),
        mem_file=str(mem_f),
        moderate_rcvbuf_file=str(mod_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_moderate_rcvbuf'] == 1
    assert res['summary']['tcp_rmem_max'] == 33554432
    assert res['summary']['prune_called'] == 100
    assert res['summary']['rcv_pruned'] == 50
    assert res['summary']['tcp_rcv_collapsed'] == 4000
    assert res['summary']['tcp_memory_pressures'] == 0
    assert res['summary']['collapse_ratio_pct'] == 0.4

    # Case 2: Auto-tuning disabled -> WARNING
    mod_f.write_text('0\n')
    res2 = mod.audit_prune_guard(
        rmem_file=str(rmem_f),
        mem_file=str(mem_f),
        moderate_rcvbuf_file=str(mod_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('auto-tuning is disabled' in iss for iss in res2['summary']['issues'])
    mod_f.write_text('1\n')

    # Case 3: High memory pressure -> CRITICAL
    netstat_f.write_text('''TcpExt: PruneCalled RcvPruned OfoPruned TCPMemoryPressures TCPRcvCollapsed TCPRcvQDrop TCPZeroWindowDrop TCPDelivered
TcpExt: 100 50 1 8 4000 50 0 1000000
''')
    res3 = mod.audit_prune_guard(
        rmem_file=str(rmem_f),
        mem_file=str(mem_f),
        moderate_rcvbuf_file=str(mod_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert res3['summary']['healthy'] is False
    assert any('global memory pressure 8 times' in iss for iss in res3['summary']['issues'])

    # Case 4: Low maximum receive buffer (< 2MB) -> WARNING
    netstat_f.write_text('''TcpExt: PruneCalled RcvPruned OfoPruned TCPMemoryPressures TCPRcvCollapsed TCPRcvQDrop TCPZeroWindowDrop TCPDelivered
TcpExt: 0 0 0 0 0 0 0 1000000
''')
    rmem_f.write_text('4096 87380 1048576\n')  # 1MB max
    res4 = mod.audit_prune_guard(
        rmem_file=str(rmem_f),
        mem_file=str(mem_f),
        moderate_rcvbuf_file=str(mod_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('buffer is low' in iss for iss in res4['summary']['issues'])

    # Case 5: Missing files fallback (fail-open)
    res5 = mod.audit_prune_guard(
        rmem_file='/nonexistent/rmem',
        mem_file='/nonexistent/mem',
        moderate_rcvbuf_file='/nonexistent/mod',
        netstat_file='/nonexistent/netstat',
    )
    assert res5['summary']['status'] == 'HEALTHY'
    assert res5['summary']['tcp_moderate_rcvbuf'] == 1
    assert res5['summary']['prune_called'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 138 regression tests passed!"
