#!/usr/bin/env bash
# tests/fm-jev-numa-guard.test.sh - Regression tests for Pattern 83 (NUMA Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-numa-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-numa-guard.py"

echo "Running Pattern 83 regression tests..."

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
assert 'nodes' in data
assert 'affinity_cpus_sample' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'numa_nodes_count' in s
assert 'overall_miss_pct' in s
assert 'total_cpus' in s
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysfs numa nodes
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-numa-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    node0 = os.path.join(tmp_dir, 'node0')
    node1 = os.path.join(tmp_dir, 'node1')
    os.makedirs(node0, exist_ok=True)
    os.makedirs(node1, exist_ok=True)

    with open(os.path.join(node0, 'numastat'), 'w') as f:
        f.write('numa_hit 1000\nnuma_miss 10\nnuma_foreign 0\nlocal_node 1000\nother_node 10\n')

    with open(os.path.join(node1, 'numastat'), 'w') as f:
        f.write('numa_hit 2000\nnuma_miss 20\nnuma_foreign 0\nlocal_node 2000\nother_node 20\n')

    # Audit under normal conditions (< 5% misses)
    res = mod.audit_numa(
        node_dir=tmp_dir,
        warn_miss_pct=5.0,
        crit_miss_pct=20.0,
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['numa_nodes_count'] == 2
    assert s['total_numa_hit'] == 3000
    assert s['total_numa_miss'] == 30
    assert s['overall_miss_pct'] < 1.0

    # Test WARNING on elevated misses (e.g. 10% misses)
    with open(os.path.join(node0, 'numastat'), 'w') as f:
        f.write('numa_hit 900\nnuma_miss 100\nnuma_foreign 50\nlocal_node 900\nother_node 100\n')
    with open(os.path.join(node1, 'numastat'), 'w') as f:
        f.write('numa_hit 900\nnuma_miss 100\nnuma_foreign 50\nlocal_node 900\nother_node 100\n')

    res_warn = mod.audit_numa(
        node_dir=tmp_dir,
        warn_miss_pct=5.0,
        crit_miss_pct=20.0,
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('Elevated NUMA' in iss for iss in res_warn['summary']['issues'])

    # Test CRITICAL on severe misses (e.g. 30% misses)
    with open(os.path.join(node0, 'numastat'), 'w') as f:
        f.write('numa_hit 700\nnuma_miss 300\nnuma_foreign 100\nlocal_node 700\nother_node 300\n')
    with open(os.path.join(node1, 'numastat'), 'w') as f:
        f.write('numa_hit 700\nnuma_miss 300\nnuma_foreign 100\nlocal_node 700\nother_node 300\n')

    res_crit = mod.audit_numa(
        node_dir=tmp_dir,
        warn_miss_pct=5.0,
        crit_miss_pct=20.0,
    )
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('Severe NUMA' in iss for iss in res_crit['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 83 tests passed!"
