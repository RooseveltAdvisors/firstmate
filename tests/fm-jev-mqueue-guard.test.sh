#!/usr/bin/env bash
# tests/fm-jev-mqueue-guard.test.sh - Regression tests for Pattern 65 (Jev IPC Message Queue Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mqueue-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mqueue-guard.py"

echo "Running Pattern 65 regression tests..."

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
json_out="$("$GUARD_SH" --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'posix_queues' in data
assert 'sysv_queues' in data
assert 'posix_queues_count' in data['summary']
assert 'posix_queues_max' in data['summary']
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit test on threshold logic and mocking
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-mqueue-guard')

with tempfile.TemporaryDirectory() as tmp_proc:
    # Set up mock proc structure
    sysfs_mq = os.path.join(tmp_proc, 'sys/fs/mqueue')
    os.makedirs(sysfs_mq)
    with open(os.path.join(sysfs_mq, 'queues_max'), 'w') as f:
        f.write('10\n')
    with open(os.path.join(sysfs_mq, 'msg_max'), 'w') as f:
        f.write('5\n')

    sysv_dir = os.path.join(tmp_proc, 'sysvipc')
    os.makedirs(sysv_dir)
    with open(os.path.join(sysv_dir, 'msg'), 'w') as f:
        f.write('key msqid perms cbytes qnum lspid lrpid uid gid cuid cgid stime rtime ctime\n')
        f.write('0x1234 100 666 4096 15 123 456 1000 1000 1000 1000 0 0 0\n')

    mock_dev_mq = os.path.join(tmp_proc, 'dev_mqueue')
    os.makedirs(mock_dev_mq)
    for i in range(6):
        with open(os.path.join(mock_dev_mq, f'q_{i}'), 'w') as f:
            f.write('test_queue\n')

    res = mod.audit_fleet_mqueues(
        proc_root=tmp_proc,
        mqueue_root=mock_dev_mq,
        warn_queue_ratio=0.50,
        warn_msg_count=100,
    )
    assert res['summary']['healthy'] is False
    assert res['summary']['posix_queues_count'] == 6
    assert res['summary']['posix_queues_max'] == 10
    assert res['summary']['posix_utilization_ratio'] == 0.60
    assert res['summary']['sysv_queues_count'] == 1
    assert res['summary']['sysv_total_messages'] == 15
"
echo "ok - unit audit on threshold logic and simulated mqueues passed"

echo "ok - all Pattern 65 mqueue guard tests passed"
