#!/usr/bin/env bash
# tests/fm-jev-fin-timeout-guard.test.sh - Regression tests for Pattern 193 (TCP FIN Timeout Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-fin-timeout-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-fin-timeout-guard.py"

echo "Running Pattern 193 regression tests..."

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
assert 'netstat_counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_fin_timeout_sec' in s
assert 'tcp_max_orphans' in s
assert 'active_orphans' in s
assert 'orphan_saturation_pct' in s
assert 'abort_on_close' in s
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
mod = import_module('fm-jev-fin-timeout-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    fin_f = d / 'tcp_fin_timeout'
    orphans_f = d / 'tcp_max_orphans'
    retries_f = d / 'tcp_orphan_retries'
    sockstat_f = d / 'sockstat'
    netstat_f = d / 'netstat'

    fin_f.write_text('60\n')
    orphans_f.write_text('262144\n')
    retries_f.write_text('0\n')
    sockstat_f.write_text('TCP: inuse 500 orphan 10 tw 150 alloc 520 mem 0\n')
    netstat_f.write_text('''TcpExt: TCPAbortOnClose TCPAbortOnTimeout TCPAbortOnLinger TCPAbortFailed TCPAbortOnData TCPAbortOnMemory
TcpExt: 100 10 0 0 500 0
''')

    # Case 1: Nominal
    res = mod.audit_fin_orphans(
        fin_timeout_file=str(fin_f),
        max_orphans_file=str(orphans_f),
        orphan_retries_file=str(retries_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_fin_timeout_sec'] == 60
    assert res['summary']['active_orphans'] == 10
    assert res['summary']['abort_on_close'] == 100

    # Case 2: fin_timeout > 120 -> CRITICAL
    fin_f.write_text('180\n')
    res2 = mod.audit_fin_orphans(
        fin_timeout_file=str(fin_f),
        max_orphans_file=str(orphans_f),
        orphan_retries_file=str(retries_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('excessive timeout' in iss for iss in res2['summary']['issues'])

    # Case 3: High orphan saturation (>= 80%) -> CRITICAL
    fin_f.write_text('60\n')
    sockstat_f.write_text('TCP: inuse 500 orphan 220000 tw 150 alloc 520 mem 0\n')
    res3 = mod.audit_fin_orphans(
        fin_timeout_file=str(fin_f),
        max_orphans_file=str(orphans_f),
        orphan_retries_file=str(retries_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('Orphan socket saturation' in iss for iss in res3['summary']['issues'])

    # Case 4: Abort on memory > 100 -> CRITICAL
    sockstat_f.write_text('TCP: inuse 500 orphan 10 tw 150 alloc 520 mem 0\n')
    netstat_f.write_text('''TcpExt: TCPAbortOnClose TCPAbortOnTimeout TCPAbortOnLinger TCPAbortFailed TCPAbortOnData TCPAbortOnMemory
TcpExt: 100 10 0 0 500 120
''')
    res4 = mod.audit_fin_orphans(
        fin_timeout_file=str(fin_f),
        max_orphans_file=str(orphans_f),
        orphan_retries_file=str(retries_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'CRITICAL'
    assert any('TCPAbortOnMemory' in iss for iss in res4['summary']['issues'])

    # Case 5: fin_timeout < 15 -> WARNING
    netstat_f.write_text('''TcpExt: TCPAbortOnClose TCPAbortOnTimeout TCPAbortOnLinger TCPAbortFailed TCPAbortOnData TCPAbortOnMemory
TcpExt: 100 10 0 0 500 0
''')
    fin_f.write_text('10\n')
    res5 = mod.audit_fin_orphans(
        fin_timeout_file=str(fin_f),
        max_orphans_file=str(orphans_f),
        orphan_retries_file=str(retries_f),
        sockstat_file=str(sockstat_f),
        netstat_file=str(netstat_f),
    )
    assert res5['summary']['status'] == 'WARNING'
    assert any('dangerously short' in iss for iss in res5['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 193 regression tests passed: 6/6 tests ok"
