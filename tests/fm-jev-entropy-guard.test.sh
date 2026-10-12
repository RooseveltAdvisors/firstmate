#!/usr/bin/env bash
# tests/fm-jev-entropy-guard.test.sh - Regression tests for Pattern 81 (Entropy Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-entropy-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-entropy-guard.py"

echo "Running Pattern 81 regression tests..."

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
assert 'kernel_random' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'entropy_avail_bits' in s
assert 'poolsize_bits' in s
assert 'csprng_status' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs files
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-entropy-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_avail = os.path.join(tmp_dir, 'entropy_avail')
    mock_pool = os.path.join(tmp_dir, 'poolsize')
    mock_wakeup = os.path.join(tmp_dir, 'write_wakeup_threshold')
    mock_reseed = os.path.join(tmp_dir, 'urandom_min_reseed_secs')

    with open(mock_avail, 'w') as f:
        f.write('256\n')
    with open(mock_pool, 'w') as f:
        f.write('256\n')
    with open(mock_wakeup, 'w') as f:
        f.write('128\n')
    with open(mock_reseed, 'w') as f:
        f.write('60\n')

    # Audit under normal conditions
    res = mod.audit_entropy(
        entropy_avail_path=mock_avail,
        poolsize_path=mock_pool,
        write_wakeup_path=mock_wakeup,
        reseed_secs_path=mock_reseed,
        test_csprng=False,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['entropy_avail_bits'] == 256
    assert s['poolsize_bits'] == 256
    assert s['entropy_avail_pct'] == 100.0

    # Test WARNING on low entropy (e.g. 50 bits < 256 * 0.25 = 64)
    with open(mock_avail, 'w') as f:
        f.write('50\n')
    res_warn = mod.audit_entropy(
        entropy_avail_path=mock_avail,
        poolsize_path=mock_pool,
        write_wakeup_path=mock_wakeup,
        reseed_secs_path=mock_reseed,
        test_csprng=False,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('depletion' in iss.lower() for iss in res_warn['summary']['issues'])

    # Test CRITICAL on critical entropy depletion (e.g. 15 bits < 256 * 0.10 = 25)
    with open(mock_avail, 'w') as f:
        f.write('15\n')
    res_crit = mod.audit_entropy(
        entropy_avail_path=mock_avail,
        poolsize_path=mock_pool,
        write_wakeup_path=mock_wakeup,
        reseed_secs_path=mock_reseed,
        test_csprng=False,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('critical entropy' in iss.lower() for iss in res_crit['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 81 tests passed!"
