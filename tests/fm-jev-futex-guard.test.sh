#!/usr/bin/env bash
# tests/fm-jev-futex-guard.test.sh - Regression tests for Pattern 63 (Jev Futex Contention & Thread Stargate Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-futex-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-futex-guard.py"

echo "Running Pattern 63 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on audit
json_out="$("$GUARD_SH" --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'top_processes' in data
assert 'flagged_processes' in data
assert isinstance(data['summary']['audited_processes'], int)
assert isinstance(data['summary']['total_threads'], int)
assert isinstance(data['summary']['total_futex_threads'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Unit test on threshold logic and mocking
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-futex-guard')

# Live test with generous thresholds -> must be healthy
res = mod.audit_fleet_futex(warn_threads=10000, warn_futex_threads=10000, warn_futex_ratio=0.99)
assert res['summary']['healthy'] is True

# Test mock proc structure with simulated futex contention
with tempfile.TemporaryDirectory() as tmp_proc:
    pid_dir = os.path.join(tmp_proc, '99999')
    task_dir = os.path.join(pid_dir, 'task')
    os.makedirs(task_dir)
    with open(os.path.join(pid_dir, 'comm'), 'w') as f:
        f.write('stuck_worker\n')
    
    # Create 10 threads, 9 in futex_wait
    for i in range(1, 11):
        t_dir = os.path.join(task_dir, str(1000 + i))
        os.makedirs(t_dir)
        with open(os.path.join(t_dir, 'wchan'), 'w') as f:
            f.write('futex_wait_queue_me\n' if i <= 9 else 'do_epoll_wait\n')
            
    mock_res = mod.audit_fleet_futex(
        proc_root=tmp_proc,
        warn_threads=10,
        warn_futex_threads=8,
        warn_futex_ratio=0.80
    )
    assert mock_res['summary']['healthy'] is False
    assert mock_res['summary']['flagged_processes_count'] == 1
    assert mock_res['flagged_processes'][0]['pid'] == 99999
    assert mock_res['flagged_processes'][0]['comm'] == 'stuck_worker'
    assert mock_res['flagged_processes'][0]['futex_wait_count'] == 9
"
echo "ok - unit audit on threshold logic and simulated contention passed"

echo "ok - all Pattern 63 futex guard tests passed"
