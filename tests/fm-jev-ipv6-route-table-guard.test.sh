#!/usr/bin/env bash
# tests/fm-jev-ipv6-route-table-guard.test.sh - Regression tests for Pattern 287 (Ipv6RouteTableGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-route-table-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-route-table-guard.py"

echo "Running Pattern 287 regression tests..."

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
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['max_size'], int)
assert isinstance(data['gc_thresh'], int)
assert isinstance(data['min_adv_mss'], int)
assert isinstance(data['active_routes'], int)
assert isinstance(data['gc_saturation_pct'], float)
assert isinstance(data['in_no_routes'], int)
assert isinstance(data['out_no_routes'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['out_discards'], int)
assert isinstance(data['table_healthy'], bool)
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
mod = import_module('fm-jev-ipv6-route-table-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    route_dir = d / 'route'
    route_dir.mkdir()
    (route_dir / 'max_size').write_text('2147483647\n')
    (route_dir / 'gc_thresh').write_text('1024\n')
    (route_dir / 'min_adv_mss').write_text('1220\n')

    route_file = d / 'ipv6_route'
    route_file.write_text('route1\nroute2\nroute3\nroute4\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6InNoRoutes 0\nIp6OutNoRoutes 100\nIp6InDiscards 10\nIp6OutDiscards 0\n')

    res = mod.audit_ipv6_route_table_guard(
        route_dir=str(route_dir),
        route_file=str(route_file),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['max_size'] == 2147483647
    assert res['gc_thresh'] == 1024
    assert res['min_adv_mss'] == 1220
    assert res['active_routes'] == 4
    assert res['gc_saturation_pct'] == 0.39

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    route_dir = d / 'route'
    route_dir.mkdir()
    (route_dir / 'max_size').write_text('500\n')
    (route_dir / 'gc_thresh').write_text('1000\n')
    (route_dir / 'min_adv_mss').write_text('1000\n')

    route_file = d / 'ipv6_route'
    route_file.write_text('entry\n' * 1005)

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6InNoRoutes 5\nIp6OutNoRoutes 200\nIp6InDiscards 0\nIp6OutDiscards 0\n')

    res = mod.audit_ipv6_route_table_guard(
        route_dir=str(route_dir),
        route_file=str(route_file),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('min_adv_mss (1000 < 1220)' in iss for iss in res['issues'])
    assert any('max_size (500) is smaller than gc_thresh (1000)' in iss for iss in res['issues'])
    assert any('saturated against GC threshold' in iss for iss in res['issues'])
    assert any('fully exhausted' in iss for iss in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All 6/6 Pattern 287 tests passed successfully!"
