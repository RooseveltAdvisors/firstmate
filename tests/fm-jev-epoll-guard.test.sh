#!/usr/bin/env bash
# tests/fm-jev-epoll-guard.test.sh - Regression tests for Pattern 85 (Epoll Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-epoll-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-epoll-guard.py"

echo "Running Pattern 85 regression tests..."

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
assert 'top_consumers' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'epoll_instances' in s
assert 'eventfd_descriptors' in s
assert 'max_user_watches' in s
assert 'watches_saturation_pct' in s
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
mod = import_module('fm-jev-epoll-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    proc_dir = os.path.join(tmp_dir, 'proc')
    sys_file = os.path.join(tmp_dir, 'max_user_watches')
    os.makedirs(proc_dir, exist_ok=True)

    with open(sys_file, 'w') as f:
        f.write('1000\n')

    # Process 101: 5 epoll, 5 eventfd
    p1 = os.path.join(proc_dir, '101')
    p1_fd = os.path.join(p1, 'fd')
    os.makedirs(p1_fd, exist_ok=True)
    with open(os.path.join(p1, 'comm'), 'w') as f: f.write('node-agent\n')
    for i in range(5):
        os.symlink('anon_inode:[eventpoll]', os.path.join(p1_fd, f'epoll_{i}'))
        os.symlink('anon_inode:[eventfd]', os.path.join(p1_fd, f'eventfd_{i}'))

    # Process 102: 10 epoll
    p2 = os.path.join(proc_dir, '102')
    p2_fd = os.path.join(p2, 'fd')
    os.makedirs(p2_fd, exist_ok=True)
    with open(os.path.join(p2, 'comm'), 'w') as f: f.write('python-worker\n')
    for i in range(10):
        os.symlink('anon_inode:[eventpoll]', os.path.join(p2_fd, f'epoll_{i}'))

    # Test healthy audit (15 / 1000 = 1.5% saturation)
    res = mod.audit_epoll(
        proc_dir=proc_dir,
        sys_epoll_path=sys_file,
        warn_watches_pct=50.0,
        crit_watches_pct=80.0,
        warn_proc_epoll=20,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['epoll_instances'] == 15
    assert s['eventfd_descriptors'] == 5
    assert s['watches_saturation_pct'] == 1.5
    assert len(s['issues']) == 0

    # Test WARNING on high saturation
    res_warn = mod.audit_epoll(
        proc_dir=proc_dir,
        sys_epoll_path=sys_file,
        warn_watches_pct=1.0,
        crit_watches_pct=80.0,
        warn_proc_epoll=20,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('Elevated epoll' in iss for iss in res_warn['summary']['issues'])

    # Test WARNING on single process leak
    res_leak = mod.audit_epoll(
        proc_dir=proc_dir,
        sys_epoll_path=sys_file,
        warn_watches_pct=50.0,
        crit_watches_pct=80.0,
        warn_proc_epoll=8, # p2 has 10
    )
    assert res_leak['summary']['status'] == 'WARNING'
    assert any('anomalous epoll' in iss for iss in res_leak['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 85 tests passed!"
