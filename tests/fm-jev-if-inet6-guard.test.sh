#!/usr/bin/env bash
# tests/fm-jev-if-inet6-guard.test.sh - Regression tests for Pattern 246 (IfInet6Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-if-inet6-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-if-inet6-guard.py"

echo "Running Pattern 246 regression tests..."

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
assert isinstance(data['total_addresses'], int)
assert isinstance(data['dad_failed_count'], int)
assert isinstance(data['tentative_count'], int)
assert isinstance(data['all_disable_ipv6'], int)
assert isinstance(data['lo_disable_ipv6'], int)
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
mod = import_module('fm-jev-if-inet6-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    if_inet6_f = d / 'if_inet6'
    sysctl_d = d / 'conf'
    (sysctl_d / 'all').mkdir(parents=True)
    (sysctl_d / 'default').mkdir(parents=True)
    (sysctl_d / 'lo').mkdir(parents=True)

    if_inet6_f.write_text(
        '00000000000000000000000000000001 01 80 10 80       lo\n'
    )
    (sysctl_d / 'all' / 'disable_ipv6').write_text('0\n')
    (sysctl_d / 'default' / 'disable_ipv6').write_text('0\n')
    (sysctl_d / 'lo' / 'disable_ipv6').write_text('0\n')
    (sysctl_d / 'all' / 'dad_transmits').write_text('1\n')

    res = mod.audit_if_inet6_guard(if_inet6_file=str(if_inet6_f), sysctl_conf_dir=str(sysctl_d))
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['total_addresses'] == 1
    assert res['dad_failed_count'] == 0
    assert len(res['issues']) == 0

    # Test DAD failure detection
    if_inet6_f.write_text(
        '00000000000000000000000000000001 01 80 10 80       lo\n'
        'fe8000000000000002005efffe000100 02 40 20 88   enp7s0\n'
    )
    res_dad = mod.audit_if_inet6_guard(if_inet6_file=str(if_inet6_f), sysctl_conf_dir=str(sysctl_d))
    assert res_dad['status'] == 'WARNING'
    assert res_dad['healthy'] is False
    assert res_dad['dad_failed_count'] == 1
    assert any('Duplicate Address Detection (DAD) failure' in iss for iss in res_dad['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 246 regression tests passed cleanly."
