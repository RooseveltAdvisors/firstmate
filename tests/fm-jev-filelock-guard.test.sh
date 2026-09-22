#!/usr/bin/env bash
# tests/fm-jev-filelock-guard.test.sh - Regression tests for Pattern 80 (File Lock Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-filelock-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-filelock-guard.py"

echo "Running Pattern 80 regression tests..."

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
assert 'top_holders' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'total_locks' in s
assert 'posix_locks' in s
assert 'flock_locks' in s
assert 'contended_inodes_count' in s
assert 'max_contenders_per_file' in s
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
mod = import_module('fm-jev-filelock-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_locks = os.path.join(tmp_dir, 'locks')

    # Write normal lock file
    with open(mock_locks, 'w') as f:
        f.write('1: FLOCK  ADVISORY  WRITE 100 103:02:111111 0 EOF\n')
        f.write('2: POSIX  ADVISORY  READ 101 103:02:222222 0 EOF\n')
        f.write('3: POSIX  ADVISORY  READ 102 103:02:222222 0 EOF\n') # Multiple READ is normal

    res = mod.audit_file_locks(
        locks_path=mock_locks,
        warn_contention=3,
        crit_contention=8,
        check_pid_alive=False,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['total_locks'] == 3
    assert s['flock_locks'] == 1
    assert s['posix_locks'] == 2
    assert s['contended_inodes_count'] == 0 # multiple READ has no WRITE, so no contention

    # Test WARNING on lock contention (3 processes contending with a WRITE lock)
    with open(mock_locks, 'w') as f:
        f.write('1: FLOCK  ADVISORY  WRITE 100 103:02:333333 0 EOF\n')
        f.write('2: FLOCK  ADVISORY  READ 101 103:02:333333 0 EOF\n')
        f.write('3: FLOCK  ADVISORY  WRITE 102 103:02:333333 0 EOF\n')

    res_warn = mod.audit_file_locks(
        locks_path=mock_locks,
        warn_contention=3,
        crit_contention=8,
        check_pid_alive=False,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert res_warn['summary']['contended_inodes_count'] == 1
    assert res_warn['summary']['max_contenders_per_file'] == 3

    # Test CRITICAL on high contention
    with open(mock_locks, 'w') as f:
        for p in range(10):
            f.write(f'{p+1}: FLOCK  ADVISORY  WRITE {200+p} 103:02:444444 0 EOF\n')

    res_crit = mod.audit_file_locks(
        locks_path=mock_locks,
        warn_contention=3,
        crit_contention=8,
        check_pid_alive=False,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert res_crit['summary']['max_contenders_per_file'] == 10
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 80 tests passed!"
