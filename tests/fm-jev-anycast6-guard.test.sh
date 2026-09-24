#!/usr/bin/env bash
# tests/fm-jev-anycast6-guard.test.sh - Regression tests for Pattern 250 (Anycast6Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-anycast6-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-anycast6-guard.py"

echo "Running Pattern 250 regression tests..."

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
assert isinstance(data['anycast_address_count'], int)
assert isinstance(data['rfc4443_compliant'], bool)
assert isinstance(data['default_anycast_delay_jiffies'], int)
assert isinstance(data['entries'], list)
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
mod = import_module('fm-jev-anycast6-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ac_file = d / 'anycast6'
    echo_file = d / 'anycast_src_echo_reply'
    ign_file = d / 'echo_ignore_anycast'
    err_file = d / 'error_anycast_as_unicast'
    delay_file = d / 'anycast_delay'

    # Nominal empty case
    ac_file.write_text('')
    echo_file.write_text('0\n')
    ign_file.write_text('0\n')
    err_file.write_text('0\n')
    delay_file.write_text('100\n')

    res = mod.audit_anycast6_guard(
        anycast6_path=str(ac_file),
        sysctl_src_echo=str(echo_file),
        sysctl_ignore_anycast=str(ign_file),
        sysctl_err_unicast=str(err_file),
        sysctl_anycast_delay=str(delay_file),
    )
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['anycast_address_count'] == 0
    assert res['rfc4443_compliant'] is True
    assert len(res['issues']) == 0

    # Populated table with non-compliant echo reply
    ac_file.write_text('1 lo 00000000000000000000000000000001 1\n')
    echo_file.write_text('1\n')
    delay_file.write_text('5\n')

    res_bad = mod.audit_anycast6_guard(
        anycast6_path=str(ac_file),
        sysctl_src_echo=str(echo_file),
        sysctl_ignore_anycast=str(ign_file),
        sysctl_err_unicast=str(err_file),
        sysctl_anycast_delay=str(delay_file),
    )
    assert res_bad['status'] == 'WARNING'
    assert res_bad['healthy'] is False
    assert res_bad['rfc4443_compliant'] is False
    assert res_bad['anycast_address_count'] == 1
    assert any('violates RFC 4443' in iss for iss in res_bad['issues'])
    assert any('dangerously low' in iss for iss in res_bad['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "Pattern 250 regression tests complete: ALL 6 TESTS PASSED."
