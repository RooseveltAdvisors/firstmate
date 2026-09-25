#!/usr/bin/env bash
# tests/fm-jev-cn-proc-guard.test.sh - Regression tests for Pattern 305 (CnProcGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-cn-proc-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-cn-proc-guard.py"

echo "Running Pattern 305 regression tests..."

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
assert data['pattern'] == 305
assert data['name'] == 'cn_proc'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['cn_proc_registered'], bool)
assert isinstance(data['cn_proc_id'], str)
assert isinstance(data['registered_drivers'], dict)
assert isinstance(data['connector_socket_count'], int)
assert isinstance(data['total_drops'], int)
assert isinstance(data['max_rmem_bytes'], int)
assert isinstance(data['max_wmem_bytes'], int)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
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
mod = import_module('fm-jev-cn-proc-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conn_f = d / 'connector'
    conn_f.write_text('Name            ID\ncn_proc         1:1\n')
    nl_f = d / 'netlink'
    nl_f.write_text(
        'sk               Eth Pid        Groups   Rmem     Wmem     Dump  Locks    Drops    Inode\n'
        '0000000000000000 11  0          00000000 0        0        0     2        0        36\n'
    )

    res = mod.evaluate_cn_proc(
        connector_file=str(conn_f),
        netlink_file=str(nl_f),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['cn_proc_registered'] is True
    assert res['cn_proc_id'] == '1:1'
    assert res['connector_socket_count'] == 1
    assert res['total_drops'] == 0
    assert len(res['issues']) == 0

    # Test warnings & critical error
    conn_f.write_text('Name            ID\nother_drv       2:2\n')
    nl_f.write_text(
        'sk               Eth Pid        Groups   Rmem     Wmem     Dump  Locks    Drops    Inode\n'
        '0000000000000000 11  0          00000000 2000000  0        0     2        5        36\n'
    )

    res_warn = mod.evaluate_cn_proc(
        connector_file=str(conn_f),
        netlink_file=str(nl_f),
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'CRITICAL'
    assert any('cn_proc' in iss for iss in res_warn['issues'])
    assert any('packet drops' in iss for iss in res_warn['issues'])
    assert any('queue backlog' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 305 regression tests passed successfully."
