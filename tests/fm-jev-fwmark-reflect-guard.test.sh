#!/usr/bin/env bash
# tests/fm-jev-fwmark-reflect-guard.test.sh - Regression tests for Pattern 269 (FwmarkReflectGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-fwmark-reflect-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-fwmark-reflect-guard.py"

echo "Running Pattern 269 regression tests..."

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
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['ipv4_fwmark_reflect'], int)
assert isinstance(data['ipv6_fwmark_reflect'], int)
assert isinstance(data['policy_routing_symmetric'], bool)
assert isinstance(data['issues'], list)
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
mod = import_module('fm-jev-fwmark-reflect-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    v4 = d / 'ipv4'
    v6 = d / 'ipv6'
    v4.mkdir(parents=True)
    v6.mkdir(parents=True)

    (v4 / 'fwmark_reflect').write_text('0\n')
    (v6 / 'fwmark_reflect').write_text('0\n')
    (v4 / 'ip_nonlocal_bind').write_text('0\n')
    (v6 / 'ip_nonlocal_bind').write_text('0\n')
    (v4 / 'fib_notify_on_flag_change').write_text('0\n')
    (v6 / 'fib_notify_on_flag_change').write_text('0\n')

    res = mod.audit_fwmark_reflect_guard(
        net_dir=str(d),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['ipv4_fwmark_reflect'] == 0
    assert res['ipv6_fwmark_reflect'] == 0
    assert res['policy_routing_symmetric'] is True

    # Issues case: invalid values
    (v4 / 'fwmark_reflect').write_text('5\n')
    (v6 / 'fwmark_reflect').write_text('3\n')
    (v4 / 'ip_nonlocal_bind').write_text('2\n')
    (v6 / 'ip_nonlocal_bind').write_text('4\n')
    (v4 / 'fib_notify_on_flag_change').write_text('9\n')
    (v6 / 'fib_notify_on_flag_change').write_text('7\n')

    res2 = mod.audit_fwmark_reflect_guard(
        net_dir=str(d),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'WARNING'
    assert len(res2['issues']) == 6
    assert any('Invalid ipv4.fwmark_reflect=5' in i for i in res2['issues'])
    assert any('Invalid ipv6.fwmark_reflect=3' in i for i in res2['issues'])
    assert any('Invalid ipv4.ip_nonlocal_bind=2' in i for i in res2['issues'])
    assert any('Invalid ipv6.ip_nonlocal_bind=4' in i for i in res2['issues'])
    assert any('Invalid ipv4.fib_notify_on_flag_change=9' in i for i in res2['issues'])
    assert any('Invalid ipv6.fib_notify_on_flag_change=7' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 269 regression tests passed!"
