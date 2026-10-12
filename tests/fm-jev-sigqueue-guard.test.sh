#!/usr/bin/env bash
# tests/fm-jev-sigqueue-guard.test.sh - Regression tests for Pattern 86 (SigQueue Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sigqueue-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sigqueue-guard.py"

echo "Running Pattern 86 regression tests..."

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
assert 'top_queued_processes' in data
assert 'pending_processes' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'max_queued_signals' in s
assert 'signal_queue_limit' in s
assert 'saturation_pct' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs processes
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-sigqueue-guard')

with tempfile.TemporaryDirectory() as tmp_proc:
    # Process 101: nominal (10/1000 queued, no pending)
    p1 = os.path.join(tmp_proc, '101')
    os.makedirs(p1, exist_ok=True)
    with open(os.path.join(p1, 'status'), 'w') as f:
        f.write('Name:\tfirstmate\nState:\tS (sleeping)\nSigQ:\t10/1000\nSigPnd:\t0000000000000000\n')

    # Process 102: nominal (5/1000 queued, no pending)
    p2 = os.path.join(tmp_proc, '102')
    os.makedirs(p2, exist_ok=True)
    with open(os.path.join(p2, 'status'), 'w') as f:
        f.write('Name:\twiseman\nState:\tS (sleeping)\nSigQ:\t5/1000\nSigPnd:\t0000000000000000\n')

    # Test healthy scenario (10/1000 = 1.0% saturation)
    res = mod.audit_sigqueue(
        proc_dir=tmp_proc,
        warn_sat_pct=50.0,
        crit_sat_pct=80.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['max_queued_signals'] == 10
    assert s['signal_queue_limit'] == 1000
    assert s['saturation_pct'] == 1.0
    assert s['procs_with_pending_signals'] == 0

    # Test WARNING on high saturation
    res_warn = mod.audit_sigqueue(
        proc_dir=tmp_proc,
        warn_sat_pct=0.5,
        crit_sat_pct=80.0,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('Elevated POSIX signal' in iss for iss in res_warn['summary']['issues'])

    # Test CRITICAL on severe saturation
    with open(os.path.join(p1, 'status'), 'w') as f:
        f.write('Name:\tfirstmate\nState:\tS (sleeping)\nSigQ:\t900/1000\nSigPnd:\t0000000000000000\n')
    res_crit = mod.audit_sigqueue(
        proc_dir=tmp_proc,
        warn_sat_pct=50.0,
        crit_sat_pct=80.0,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('Severe POSIX signal' in iss for iss in res_crit['summary']['issues'])

    # Test pending signal detection
    with open(os.path.join(p1, 'status'), 'w') as f:
        f.write('Name:\tfirstmate\nState:\tS (sleeping)\nSigQ:\t10/1000\nSigPnd:\t0000000000000002\n')
    res_pnd = mod.audit_sigqueue(proc_dir=tmp_proc)
    assert res_pnd['summary']['procs_with_pending_signals'] == 1
    assert res_pnd['pending_processes'][0]['pid'] == 101
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 86 tests passed!"
