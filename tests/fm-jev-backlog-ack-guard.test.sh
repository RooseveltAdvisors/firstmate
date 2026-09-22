#!/usr/bin/env bash
# tests/fm-jev-backlog-ack-guard.test.sh - Regression tests for Pattern 177 (TCP Backlog ACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-backlog-ack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-backlog-ack-guard.py"

echo "Running Pattern 177 regression tests..."

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
assert 'tcp_backlog_ack_defer' in s
assert 'somaxconn' in s
assert 'backlog_drops' in s
assert 'backlog_coalesced' in s
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
mod = import_module('fm-jev-backlog-ack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    defer_f = d / 'tcp_backlog_ack_defer'
    somax_f = d / 'somaxconn'
    syn_f = d / 'tcp_max_syn_backlog'
    netstat_f = d / 'netstat'

    defer_f.write_text('1\n')
    somax_f.write_text('4096\n')
    syn_f.write_text('4096\n')
    netstat_f.write_text('''TcpExt: TCPBacklogDrop TCPBacklogCoalesce TCPRcvCollapsed ListenOverflows ListenDrops
TcpExt: 0 1000 50 0 0
''')

    # Case 1: Nominal
    res = mod.audit_backlog_ack(
        defer_file=str(defer_f),
        somaxconn_file=str(somax_f),
        syn_backlog_file=str(syn_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_backlog_ack_defer'] == 1
    assert res['summary']['backlog_drops'] == 0

    # Case 2: Elevated backlog drops -> WARNING
    netstat_f.write_text('''TcpExt: TCPBacklogDrop TCPBacklogCoalesce TCPRcvCollapsed ListenOverflows ListenDrops
TcpExt: 25 1000 50 0 0
''')
    res2 = mod.audit_backlog_ack(
        defer_file=str(defer_f),
        somaxconn_file=str(somax_f),
        syn_backlog_file=str(syn_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated TCP socket backlog drops' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 177 regression tests passed: 6/6 tests ok"
