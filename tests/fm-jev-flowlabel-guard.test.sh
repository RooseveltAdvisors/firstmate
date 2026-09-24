#!/usr/bin/env bash
# tests/fm-jev-flowlabel-guard.test.sh - Regression tests for Pattern 245 (FlowlabelGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-flowlabel-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-flowlabel-guard.py"

echo "Running Pattern 245 regression tests..."

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
assert isinstance(data['active_flowlabels'], int)
assert isinstance(data['total_users'], int)
assert isinstance(data['auto_flowlabels'], int)
assert isinstance(data['flowlabel_consistency'], int)
assert isinstance(data['flowlabel_reflect'], int)
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
mod = import_module('fm-jev-flowlabel-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    flowlabel_f = d / 'ip6_flowlabel'
    sysctl_d = d / 'ipv6'
    sysctl_d.mkdir()

    flowlabel_f.write_text(
        'Label S Owner  Users  Linger Expires  Dst                              Opt\n'
        '00001 0 1000   2      0      0        ::1                              \n'
        '00002 0 1000   1      0      0        fe80::1                          \n'
    )
    (sysctl_d / 'auto_flowlabels').write_text('1\n')
    (sysctl_d / 'flowlabel_consistency').write_text('1\n')
    (sysctl_d / 'flowlabel_reflect').write_text('0\n')
    (sysctl_d / 'flowlabel_state_ranges').write_text('0\n')
    (sysctl_d / 'seg6_flowlabel').write_text('0\n')

    res = mod.audit_flowlabel_guard(flowlabel_file=str(flowlabel_f), sysctl_dir=str(sysctl_d))
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['healthy'] is True
    assert res['active_flowlabels'] == 2
    assert res['total_users'] == 3
    assert len(res['issues']) == 0

    # Test warning on consistency disabled
    (sysctl_d / 'flowlabel_consistency').write_text('0\n')
    res_warn = mod.audit_flowlabel_guard(flowlabel_file=str(flowlabel_f), sysctl_dir=str(sysctl_d))
    assert res_warn['status'] == 'WARNING'
    assert res_warn['healthy'] is False
    assert any('consistency check is disabled' in iss for iss in res_warn['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 245 regression tests passed cleanly."
