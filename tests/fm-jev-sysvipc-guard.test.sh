#!/usr/bin/env bash
# tests/fm-jev-sysvipc-guard.test.sh - Regression tests for Pattern 73 (System V IPC Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sysvipc-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sysvipc-guard.py"

echo "Running Pattern 73 regression tests..."

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
assert 'limits' in data
assert 'segments' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'shm_segment_count' in s
assert 'shm_max_segments' in s
assert 'shm_saturation_ratio' in s
assert 'zero_attach_segments' in s
assert 'orphaned_segments' in s
assert 'sem_array_count' in s
assert 'msg_queue_count' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs and orphan detection
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-sysvipc-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_shm = os.path.join(tmp_dir, 'shm')
    mock_sem = os.path.join(tmp_dir, 'sem')
    mock_msg = os.path.join(tmp_dir, 'msg')
    mock_shmmni = os.path.join(tmp_dir, 'shmmni')
    mock_sem_sysctl = os.path.join(tmp_dir, 'sem_sysctl')
    mock_proc = os.path.join(tmp_dir, 'proc')
    os.makedirs(mock_proc, exist_ok=True)

    # Mock an alive PID (1234)
    alive_pid_dir = os.path.join(mock_proc, '1234')
    os.makedirs(alive_pid_dir, exist_ok=True)

    # Write shm file:
    # Segment 1: attached (nattch=2), cpid=1234 (alive)
    # Segment 2: zero-attached (nattch=0), cpid=9999 (dead) -> ORPHAN
    # Segment 3: zero-attached (nattch=0), cpid=1234 (alive) -> NOT orphan
    shm_header = '       key      shmid perms                  size  cpid  lpid nattch   uid   gid  cuid  cgid      atime      dtime      ctime                   rss                  swap\n'
    shm_line1  = '  92043565      98315   600               1048576  1234  1234      2  1000  1000  1000  1000 1790034343 1790034343 1787590272                     0                  4096\n'
    shm_line2  = '   2752784     163866   600              10485760  9999  9999      0  1000  1000  1000  1000 1790034339 1790034339 1789975848                     0                  4096\n'
    shm_line3  = ' 119590860     131105   600                524288  1234  1234      0  1000  1000  1000  1000 1790034346 1790034346 1789972366                     0                  4096\n'
    with open(mock_shm, 'w') as f:
        f.write(shm_header + shm_line1 + shm_line2 + shm_line3)

    # Write sem file
    sem_header = '       key      semid perms      nsems   uid   gid  cuid  cgid      otime      ctime\n'
    sem_line1  = '   1122334      10001   666          5  1000  1000  1000  1000 1790034343 1790034343\n'
    with open(mock_sem, 'w') as f:
        f.write(sem_header + sem_line1)

    # Write msg file
    msg_header = '       key      msqid perms      cbytes       qnum lspid lrpid   uid   gid  cuid  cgid      stime      rtime      ctime\n'
    with open(mock_msg, 'w') as f:
        f.write(msg_header)

    # Write sysctls
    with open(mock_shmmni, 'w') as f:
        f.write('10\n')  # small limit so 3/10 = 30%
    with open(mock_sem_sysctl, 'w') as f:
        f.write('32000 1024000 500 100\n')

    # Audit under normal thresholds
    res = mod.audit_sysvipc(
        shm_path=mock_shm,
        sem_path=mock_sem,
        msg_path=mock_msg,
        shmmni_path=mock_shmmni,
        sem_path_sysctl=mock_sem_sysctl,
        check_pids=True,
        proc_root=mock_proc,
        warn_sat=0.50,
        crit_sat=0.80,
    )
    s = res['summary']
    assert s['shm_segment_count'] == 3
    assert s['shm_max_segments'] == 10
    assert s['zero_attach_segments'] == 2
    assert s['orphaned_segments'] == 1
    assert s['orphaned_bytes'] == 10485760
    assert s['sem_array_count'] == 1
    assert s['status'] == 'HEALTHY'

    # Test WARNING trigger on low orphan byte threshold
    res_warn = mod.audit_sysvipc(
        shm_path=mock_shm,
        sem_path=mock_sem,
        msg_path=mock_msg,
        shmmni_path=mock_shmmni,
        sem_path_sysctl=mock_sem_sysctl,
        check_pids=True,
        proc_root=mock_proc,
        warn_orphan_bytes=5000000, # 5MB < 10MB
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert len(res_warn['summary']['issues']) > 0

    # Test CRITICAL trigger on saturation ratio
    res_crit = mod.audit_sysvipc(
        shm_path=mock_shm,
        sem_path=mock_sem,
        msg_path=mock_msg,
        shmmni_path=mock_shmmni,
        sem_path_sysctl=mock_sem_sysctl,
        check_pids=True,
        proc_root=mock_proc,
        crit_sat=0.25, # 30% > 25%
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 73 tests passed!"
