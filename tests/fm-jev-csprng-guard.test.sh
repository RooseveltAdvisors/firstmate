#!/usr/bin/env bash
# tests/fm-jev-csprng-guard.test.sh - Regression tests for Pattern 314 (CsprngGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-csprng-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-csprng-guard.py"

echo "Running Pattern 314 regression tests..."

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
assert data['pattern'] == 314
assert data['name'] == 'csprng'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_entropy_sufficient'], bool)
assert isinstance(data['entropy_avail'], int)
assert isinstance(data['poolsize'], int)
assert isinstance(data['entropy_ratio_pct'], (int, float))
assert isinstance(data['urandom_min_reseed_secs'], int)
assert isinstance(data['write_wakeup_threshold'], int)
assert isinstance(data['boot_id'], str)
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
mod = import_module('fm-jev-csprng-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'entropy_avail').write_text('256\n')
    (d / 'poolsize').write_text('256\n')
    (d / 'urandom_min_reseed_secs').write_text('60\n')
    (d / 'write_wakeup_threshold').write_text('256\n')
    (d / 'boot_id').write_text('test-boot-uuid-1234\n')

    res = mod.evaluate_csprng(random_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_entropy_sufficient'] is True
    assert res['entropy_avail'] == 256
    assert res['poolsize'] == 256
    assert res['entropy_ratio_pct'] == 100.0
    assert res['urandom_min_reseed_secs'] == 60
    assert res['write_wakeup_threshold'] == 256
    assert res['boot_id'] == 'test-boot-uuid-1234'
    assert len(res['issues']) == 0

    # Test warning for low entropy
    (d / 'entropy_avail').write_text('50\n')
    res_warn = mod.evaluate_csprng(random_dir=str(d))
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert any('entropy pool low' in iss for iss in res_warn['issues'])

    # Test critical for exhausted entropy
    (d / 'entropy_avail').write_text('0\n')
    res_crit = mod.evaluate_csprng(random_dir=str(d))
    assert res_crit['healthy'] is False
    assert res_crit['status'] == 'CRITICAL'
    assert any('completely exhausted' in iss for iss in res_crit['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 314 regression tests passed successfully."
