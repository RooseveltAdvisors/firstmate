#!/usr/bin/env bash
# tests/fm-jev-namespace-guard.test.sh - Regression tests for Pattern 82 (Namespace Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-namespace-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-namespace-guard.py"

echo "Running Pattern 82 regression tests..."

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
assert 'named_netns' in data
assert 'sample_isolated_processes' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'processes_scanned' in s
assert 'isolated_processes_count' in s
assert 'unique_counts' in s
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
mod = import_module('fm-jev-namespace-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_proc = os.path.join(tmp_dir, 'proc')
    mock_netns = os.path.join(tmp_dir, 'run_netns')
    os.makedirs(mock_netns, exist_ok=True)

    # PID 1 (root namespaces)
    p1_ns = os.path.join(mock_proc, '1', 'ns')
    os.makedirs(p1_ns, exist_ok=True)
    with open(os.path.join(mock_proc, '1', 'comm'), 'w') as f:
        f.write('systemd\n')
    for ns_type in mod.NS_TYPES:
        os.symlink(f'{ns_type}:[1000]', os.path.join(p1_ns, ns_type))

    # PID 100 (normal process, shares root namespaces)
    p100_ns = os.path.join(mock_proc, '100', 'ns')
    os.makedirs(p100_ns, exist_ok=True)
    with open(os.path.join(mock_proc, '100', 'comm'), 'w') as f:
        f.write('bash\n')
    for ns_type in mod.NS_TYPES:
        os.symlink(f'{ns_type}:[1000]', os.path.join(p100_ns, ns_type))

    # PID 200 (isolated container, custom net and mnt)
    p200_ns = os.path.join(mock_proc, '200', 'ns')
    os.makedirs(p200_ns, exist_ok=True)
    with open(os.path.join(mock_proc, '200', 'comm'), 'w') as f:
        f.write('chrome-sandbox\n')
    for ns_type in mod.NS_TYPES:
        val = '2000' if ns_type in ('net', 'mnt') else '1000'
        os.symlink(f'{ns_type}:[{val}]', os.path.join(p200_ns, ns_type))

    # Normal audit
    res = mod.audit_namespaces(
        proc_root=mock_proc,
        netns_root=mock_netns,
        warn_isolated=5,
        crit_isolated=10,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['processes_scanned'] == 3
    assert s['isolated_processes_count'] == 1
    assert res['sample_isolated_processes'][0]['pid'] == 200
    assert set(res['sample_isolated_processes'][0]['isolated_types']) == {'net', 'mnt'}

    # Test WARNING on high isolated processes
    res_warn = mod.audit_namespaces(
        proc_root=mock_proc,
        netns_root=mock_netns,
        warn_isolated=1,
        crit_isolated=10,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('Elevated isolated' in iss for iss in res_warn['summary']['issues'])

    # Test CRITICAL on critical threshold
    res_crit = mod.audit_namespaces(
        proc_root=mock_proc,
        netns_root=mock_netns,
        warn_isolated=1,
        crit_isolated=1,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 82 tests passed!"
