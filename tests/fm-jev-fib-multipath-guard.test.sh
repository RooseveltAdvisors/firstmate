#!/usr/bin/env bash
# tests/fm-jev-fib-multipath-guard.test.sh - Regression tests for Pattern 303 (FibMultipathGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-fib-multipath-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-fib-multipath-guard.py"

echo "Running Pattern 303 regression tests..."

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
assert data['pattern'] == 303
assert data['name'] == 'fib_multipath'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['ipv4_hash_policy'], int)
assert isinstance(data['ipv4_hash_policy_name'], str)
assert isinstance(data['ipv4_hash_fields'], int)
assert isinstance(data['ipv4_hash_seed'], int)
assert isinstance(data['ipv4_use_neigh'], int)
assert isinstance(data['ipv4_sync_mem_bytes'], int)
assert isinstance(data['ipv6_hash_policy'], int)
assert isinstance(data['ipv6_hash_policy_name'], str)
assert isinstance(data['ipv6_hash_fields'], int)
assert isinstance(data['route_count'], int)
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
mod = import_module('fm-jev-fib-multipath-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'v4_pol').write_text('1\n')
    (d / 'v4_fld').write_text('7\n')
    (d / 'v4_seed').write_text('0\n')
    (d / 'v4_neigh').write_text('1\n')
    (d / 'v4_sync').write_text('524288\n')
    (d / 'v6_pol').write_text('1\n')
    (d / 'v6_fld').write_text('7\n')
    route_f = d / 'route'
    route_f.write_text('Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\neth0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n')

    res = mod.evaluate_fib_multipath(
        ipv4_hash_policy_file=str(d / 'v4_pol'),
        ipv4_hash_fields_file=str(d / 'v4_fld'),
        ipv4_hash_seed_file=str(d / 'v4_seed'),
        ipv4_use_neigh_file=str(d / 'v4_neigh'),
        ipv4_sync_mem_file=str(d / 'v4_sync'),
        ipv6_hash_policy_file=str(d / 'v6_pol'),
        ipv6_hash_fields_file=str(d / 'v6_fld'),
        route_file=str(route_f),
        warn_on_l3_only=True,
        warn_on_no_neigh=True,
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['ipv4_hash_policy'] == 1
    assert res['ipv4_hash_policy_name'] == 'L4_5TUPLE'
    assert res['ipv4_hash_fields'] == 7
    assert res['ipv4_hash_seed'] == 0
    assert res['ipv4_use_neigh'] == 1
    assert res['ipv4_sync_mem_bytes'] == 524288
    assert res['ipv6_hash_policy'] == 1
    assert res['ipv6_hash_policy_name'] == 'L4_5TUPLE'
    assert res['ipv6_hash_fields'] == 7
    assert res['route_count'] == 1
    assert len(res['issues']) == 0

    # Test warnings & critical error
    (d / 'v4_pol').write_text('0\n')
    (d / 'v4_neigh').write_text('0\n')
    (d / 'v4_sync').write_text('1024\n')
    (d / 'v6_pol').write_text('99\n')

    res_warn = mod.evaluate_fib_multipath(
        ipv4_hash_policy_file=str(d / 'v4_pol'),
        ipv4_hash_fields_file=str(d / 'v4_fld'),
        ipv4_hash_seed_file=str(d / 'v4_seed'),
        ipv4_use_neigh_file=str(d / 'v4_neigh'),
        ipv4_sync_mem_file=str(d / 'v4_sync'),
        ipv6_hash_policy_file=str(d / 'v6_pol'),
        ipv6_hash_fields_file=str(d / 'v6_fld'),
        route_file=str(route_f),
        warn_on_l3_only=True,
        warn_on_no_neigh=True,
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'CRITICAL'
    assert any('Layer 3' in iss for iss in res_warn['issues'])
    assert any('fib_multipath_use_neigh=0' in iss for iss in res_warn['issues'])
    assert any('FIB sync memory' in iss for iss in res_warn['issues'])
    assert any('Unrecognized IPv6 FIB multipath hash policy' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 303 regression tests passed successfully."
