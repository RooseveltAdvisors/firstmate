#!/usr/bin/env bash
# tests/fm-jev-sysv-ipc-guard.test.sh - Regression tests for Pattern 313 (SysVIpcGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sysv-ipc-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sysv-ipc-guard.py"

echo "Running Pattern 313 regression tests..."

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
assert data['pattern'] == 313
assert data['name'] == 'sysv_ipc'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_ipc_healthy'], bool)
assert isinstance(data['shm_segments'], int)
assert isinstance(data['shm_total_bytes'], int)
assert isinstance(data['shm_unattached'], int)
assert isinstance(data['shm_max_segments'], int)
assert isinstance(data['shm_utilization_pct'], (int, float))
assert isinstance(data['sem_arrays'], int)
assert isinstance(data['sem_total_nsems'], int)
assert isinstance(data['sem_max_arrays'], int)
assert isinstance(data['sem_utilization_pct'], (int, float))
assert isinstance(data['semmsl'], int)
assert isinstance(data['semmns'], int)
assert isinstance(data['semopm'], int)
assert isinstance(data['msg_queues'], int)
assert isinstance(data['msg_total_messages'], int)
assert isinstance(data['msg_total_bytes'], int)
assert isinstance(data['msg_max_queues'], int)
assert isinstance(data['msg_utilization_pct'], (int, float))
assert isinstance(data['msgmax'], int)
assert isinstance(data['msgmnb'], int)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked directory & sysctls
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-sysv-ipc-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ipc_dir = d / 'sysvipc'
    ipc_dir.mkdir()
    kernel_dir = d / 'kernel'
    kernel_dir.mkdir()

    # Create dummy sysvipc files
    # shm: header + 2 segments (1 attached, 1 unattached)
    shm_content = (
        '       key      shmid perms                  size  cpid  lpid nattch   uid   gid  cuid  cgid      atime      dtime      ctime                   rss                  swap\n'
        '         0          1   600               1048576 12345 12346      1  1000  1000  1000  1000 1790000000 1790000000 1790000000                4096                     0\n'
        '         0          2   600                 65536 12345 12347      0  1000  1000  1000  1000 1790000000 1790000000 1790000000                4096                     0\n'
    )
    (ipc_dir / 'shm').write_text(shm_content)

    # sem: header + 1 array with 4 semaphores
    sem_content = (
        '       key      semid perms      nsems   uid   gid  cuid  cgid      otime      ctime\n'
        '         0          1   666          4  1000  1000  1000  1000 1790000000 1790000000\n'
    )
    (ipc_dir / 'sem').write_text(sem_content)

    # msg: header + 1 queue with 5 messages, 2048 bytes
    msg_content = (
        '       key      msqid perms      cbytes       qnum lspid lrpid   uid   gid  cuid  cgid      stime      rtime      ctime\n'
        '         0          1   666        2048          5 12345 12346  1000  1000  1000  1000 1790000000 1790000000 1790000000\n'
    )
    (ipc_dir / 'msg').write_text(msg_content)

    (kernel_dir / 'shmmni').write_text('4096\n')
    (kernel_dir / 'sem').write_text('32000 1024000000 500 32000\n')
    (kernel_dir / 'msgmni').write_text('32000\n')
    (kernel_dir / 'msgmax').write_text('8192\n')
    (kernel_dir / 'msgmnb').write_text('16384\n')

    res = mod.evaluate_sysv_ipc(sysvipc_dir=str(ipc_dir), kernel_dir=str(kernel_dir))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_ipc_healthy'] is True
    assert res['shm_segments'] == 2
    assert res['shm_total_bytes'] == 1048576 + 65536
    assert res['shm_unattached'] == 1
    assert res['sem_arrays'] == 1
    assert res['sem_total_nsems'] == 4
    assert res['msg_queues'] == 1
    assert res['msg_total_messages'] == 5
    assert res['msg_total_bytes'] == 2048
    assert len(res['issues']) == 0

    # Test warning for unattached shm leak
    res_warn = mod.evaluate_sysv_ipc(
        sysvipc_dir=str(ipc_dir),
        kernel_dir=str(kernel_dir),
        warn_unattached_shm=1,
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert any('unattached' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked directory passed"

echo "All Pattern 313 regression tests passed successfully."
