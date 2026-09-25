#!/usr/bin/env bash
# tests/fm-jev-binfmt-misc-guard.test.sh - Regression tests for Pattern 307 (BinfmtMiscGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-binfmt-misc-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-binfmt-misc-guard.py"

echo "Running Pattern 307 regression tests..."

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
assert data['pattern'] == 307
assert data['name'] == 'binfmt_misc'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['binfmt_status'], str)
assert isinstance(data['total_registered'], int)
assert isinstance(data['enabled_count'], int)
assert isinstance(data['disabled_count'], int)
assert isinstance(data['handlers'], dict)
assert isinstance(data['missing_interpreters'], list)
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
mod = import_module('fm-jev-binfmt-misc-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    status_f = d / 'status'
    status_f.write_text('enabled\n')
    interp_dummy = d / 'mock_interp'
    interp_dummy.write_text('#!/bin/sh\n')

    entry1 = d / 'qemu-arm'
    entry1.write_text(
        'enabled\n'
        'interpreter ' + str(interp_dummy) + '\n'
        'flags: POCF\n'
        'offset 0\n'
        'magic 7f454c46\n'
        'mask ffffffff\n'
    )

    res = mod.evaluate_binfmt_misc(
        binfmt_dir=str(d),
        status_file=str(status_f),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['binfmt_status'] == 'enabled'
    assert res['total_registered'] == 1
    assert res['enabled_count'] == 1
    assert res['disabled_count'] == 0
    assert len(res['missing_interpreters']) == 0
    assert len(res['issues']) == 0

    # Test disabled status and missing interpreter
    status_f.write_text('disabled\n')
    entry2 = d / 'broken-emulator'
    entry2.write_text(
        'enabled\n'
        'interpreter /nonexistent/path/to/qemu-mips\n'
        'flags: OC\n'
        'offset 0\n'
    )

    res_warn = mod.evaluate_binfmt_misc(
        binfmt_dir=str(d),
        status_file=str(status_f),
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert 'broken-emulator' in res_warn['missing_interpreters']
    assert any('globally disabled' in iss for iss in res_warn['issues'])
    assert any('missing interpreters' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 307 regression tests passed successfully."
