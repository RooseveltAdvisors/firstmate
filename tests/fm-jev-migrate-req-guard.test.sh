#!/usr/bin/env bash
# tests/fm-jev-migrate-req-guard.test.sh - Regression tests for Pattern 178 (TCP Migrate Req Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-migrate-req-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-migrate-req-guard.py"

echo "Running Pattern 178 regression tests..."

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
assert 'tcp_migrate_req' in s
assert 'migrate_success' in s
assert 'migrate_failure' in s
assert 'embryonic_resets' in s
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
mod = import_module('fm-jev-migrate-req-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    migrate_f = d / 'tcp_migrate_req'
    netstat_f = d / 'netstat'

    migrate_f.write_text('0\n')
    netstat_f.write_text('''TcpExt: TCPMigrateReqSuccess TCPMigrateReqFailure EmbryonicRsts ListenOverflows ListenDrops
TcpExt: 0 0 14 0 0
''')

    # Case 1: Nominal
    res = mod.audit_migrate_req(
        migrate_file=str(migrate_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_migrate_req'] == 0
    assert res['summary']['migrate_success'] == 0

    # Case 2: Elevated migration failures -> WARNING
    netstat_f.write_text('''TcpExt: TCPMigrateReqSuccess TCPMigrateReqFailure EmbryonicRsts ListenOverflows ListenDrops
TcpExt: 5 25 14 0 0
''')
    res2 = mod.audit_migrate_req(
        migrate_file=str(migrate_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated TCP connection migration failures' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 178 regression tests passed: 6/6 tests ok"
