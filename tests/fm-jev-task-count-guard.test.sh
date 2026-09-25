#!/usr/bin/env bash
# tests/fm-jev-task-count-guard.test.sh - Regression tests for Pattern 310 (TaskCountGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-task-count-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-task-count-guard.py"

echo "Running Pattern 310 regression tests..."

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
assert data['pattern'] == 310
assert data['name'] == 'task_count'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['load_1m'], (int, float))
assert isinstance(data['load_5m'], (int, float))
assert isinstance(data['load_15m'], (int, float))
assert isinstance(data['runnable_tasks'], int)
assert isinstance(data['total_tasks'], int)
assert isinstance(data['threads_max'], int)
assert isinstance(data['thread_utilization_pct'], (int, float))
assert isinstance(data['last_pid'], int)
assert isinstance(data['pid_max'], int)
assert isinstance(data['pid_utilization_pct'], (int, float))
assert isinstance(data['max_map_count'], int)
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
mod = import_module('fm-jev-task-count-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'loadavg').write_text('1.50 2.00 1.80 5/1000 12345\n')
    (d / 'threads-max').write_text('100000\n')
    (d / 'pid_max').write_text('4194304\n')
    (d / 'max_map_count').write_text('1048576\n')

    res = mod.evaluate_task_count(
        loadavg_file=str(d / 'loadavg'),
        threads_max_file=str(d / 'threads-max'),
        pid_max_file=str(d / 'pid_max'),
        max_map_count_file=str(d / 'max_map_count'),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['load_1m'] == 1.50
    assert res['runnable_tasks'] == 5
    assert res['total_tasks'] == 1000
    assert res['threads_max'] == 100000
    assert res['thread_utilization_pct'] == 1.0
    assert res['last_pid'] == 12345
    assert len(res['issues']) == 0

    # Test warnings & critical saturation
    (d / 'loadavg').write_text('150.0 120.0 90.0 600/95000 4100000\n')
    res_crit = mod.evaluate_task_count(
        loadavg_file=str(d / 'loadavg'),
        threads_max_file=str(d / 'threads-max'),
        pid_max_file=str(d / 'pid_max'),
        max_map_count_file=str(d / 'max_map_count'),
    )
    assert res_crit['healthy'] is False
    assert res_crit['status'] == 'CRITICAL'
    assert any('Thread count critically elevated' in iss for iss in res_crit['issues'])
    assert any('Runnable task count critical' in iss for iss in res_crit['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 310 regression tests passed successfully."
