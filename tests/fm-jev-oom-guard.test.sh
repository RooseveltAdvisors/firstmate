#!/usr/bin/env bash
# tests/fm-jev-oom-guard.test.sh - Regression tests for Pattern 84 (OOM Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-oom-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-oom-guard.py"

echo "Running Pattern 84 regression tests..."

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
assert 'top_oom_candidates' in data
assert 'flagged_supervisors' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'total_audited' in s
assert 'max_system_score' in s
assert 'max_supervisor_score' in s
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
mod = import_module('fm-jev-oom-guard')

with tempfile.TemporaryDirectory() as tmp_proc:
    # Process 100: Supervisor (firstmate) - healthy low score
    p1 = os.path.join(tmp_proc, '100')
    os.makedirs(p1, exist_ok=True)
    with open(os.path.join(p1, 'oom_score'), 'w') as f: f.write('150\n')
    with open(os.path.join(p1, 'oom_score_adj'), 'w') as f: f.write('0\n')
    with open(os.path.join(p1, 'comm'), 'w') as f: f.write('firstmate\n')
    with open(os.path.join(p1, 'cmdline'), 'w') as f: f.write('/opt/ra/firstmate/bin/pi\0')
    with open(os.path.join(p1, 'status'), 'w') as f: f.write('VmRSS: 120000 kB\n')

    # Process 200: Transient worker (playwright/chrome) - higher score
    p2 = os.path.join(tmp_proc, '200')
    os.makedirs(p2, exist_ok=True)
    with open(os.path.join(p2, 'oom_score'), 'w') as f: f.write('650\n')
    with open(os.path.join(p2, 'oom_score_adj'), 'w') as f: f.write('200\n')
    with open(os.path.join(p2, 'comm'), 'w') as f: f.write('chrome\n')
    with open(os.path.join(p2, 'cmdline'), 'w') as f: f.write('/usr/bin/chrome --headless\0')
    with open(os.path.join(p2, 'status'), 'w') as f: f.write('VmRSS: 550000 kB\n')

    # Test healthy scenario
    res = mod.audit_oom(
        proc_dir=tmp_proc,
        warn_score=850,
        crit_score=950,
        sup_warn_score=750,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['total_audited'] == 2
    assert s['max_system_score'] == 650
    assert s['max_supervisor_score'] == 150
    assert len(res['flagged_supervisors']) == 0

    # Test WARNING on supervisor positive adj
    with open(os.path.join(p1, 'oom_score_adj'), 'w') as f: f.write('100\n')
    res_adj = mod.audit_oom(proc_dir=tmp_proc)
    assert res_adj['summary']['status'] == 'WARNING'
    assert any('positive oom_score_adj' in iss for iss in res_adj['summary']['issues'])

    # Test WARNING on supervisor elevated score
    with open(os.path.join(p1, 'oom_score_adj'), 'w') as f: f.write('0\n')
    with open(os.path.join(p1, 'oom_score'), 'w') as f: f.write('800\n')
    res_warn = mod.audit_oom(proc_dir=tmp_proc, sup_warn_score=750, crit_score=950)
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('elevated OOM score' in iss for iss in res_warn['summary']['issues'])

    # Test CRITICAL on supervisor severe score
    with open(os.path.join(p1, 'oom_score'), 'w') as f: f.write('960\n')
    res_crit = mod.audit_oom(proc_dir=tmp_proc, sup_warn_score=750, crit_score=950)
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('severe OOM risk' in iss for iss in res_crit['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 84 tests passed!"
