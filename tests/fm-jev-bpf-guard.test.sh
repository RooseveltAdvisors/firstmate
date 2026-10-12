#!/usr/bin/env bash
# tests/fm-jev-bpf-guard.test.sh - Regression tests for Pattern 75 (eBPF Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-bpf-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-bpf-guard.py"

echo "Running Pattern 75 regression tests..."

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
assert 'unprivileged_bpf_disabled' in s
assert 'bpf_jit_enable' in s
assert 'active_bpf_fds' in s
assert 'pinned_bpf_objects' in s
assert isinstance(s['bpf_fs_accessible'], bool)
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs and sysctls
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-bpf-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_proc = os.path.join(tmp_dir, 'proc')
    mock_bpf_fs = os.path.join(tmp_dir, 'bpf_fs')
    os.makedirs(mock_bpf_fs, exist_ok=True)

    # Create mock process 4242 with 2 BPF FDs
    p4242_fd = os.path.join(mock_proc, '4242', 'fd')
    os.makedirs(p4242_fd, exist_ok=True)
    with open(os.path.join(mock_proc, '4242', 'comm'), 'w') as f:
        f.write('cilium-agent\n')
    os.symlink('anon_inode:bpf-map', os.path.join(p4242_fd, '3'))
    os.symlink('anon_inode:bpf-prog', os.path.join(p4242_fd, '4'))
    os.symlink('/dev/null', os.path.join(p4242_fd, '0'))

    # Create pinned objects in mock bpf_fs
    with open(os.path.join(mock_bpf_fs, 'my_pinned_map'), 'w') as f:
        f.write('')

    # Create mock sysctls
    mock_unpriv = os.path.join(tmp_dir, 'unpriv')
    with open(mock_unpriv, 'w') as f:
        f.write('2\n')

    mock_jit = os.path.join(tmp_dir, 'jit')
    with open(mock_jit, 'w') as f:
        f.write('1\n')

    # Audit under normal thresholds
    res = mod.audit_bpf(
        unpriv_path=mock_unpriv,
        jit_path=mock_jit,
        bpf_fs=mock_bpf_fs,
        proc_root=mock_proc,
        warn_active_fds=10,
        crit_active_fds=20,
        warn_pinned_objs=5,
        crit_pinned_objs=10,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['unprivileged_bpf_disabled'] == 2
    assert s['bpf_jit_enable'] == 1
    assert s['active_bpf_fds'] == 2
    assert s['pinned_bpf_objects'] == 1
    assert s['bpf_fs_accessible'] is True
    assert s['processes_with_bpf'] == 1
    assert res['top_consumers'][0]['comm'] == 'cilium-agent'

    # Test WARNING on unprivileged bpf = 0
    with open(mock_unpriv, 'w') as f:
        f.write('0\n')
    res_warn_unpriv = mod.audit_bpf(
        unpriv_path=mock_unpriv,
        jit_path=mock_jit,
        bpf_fs=mock_bpf_fs,
        proc_root=mock_proc,
    )
    assert res_warn_unpriv['summary']['status'] == 'WARNING'
    assert any('Unprivileged' in iss for iss in res_warn_unpriv['summary']['issues'])

    # Test CRITICAL on active BPF FDs
    res_crit = mod.audit_bpf(
        unpriv_path=mock_unpriv,
        jit_path=mock_jit,
        bpf_fs=mock_bpf_fs,
        proc_root=mock_proc,
        crit_active_fds=1, # 2 >= 1 -> CRITICAL
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 75 tests passed!"
