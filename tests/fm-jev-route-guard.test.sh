#!/usr/bin/env bash
# tests/fm-jev-route-guard.test.sh - Regression tests for Pattern 93 (Route Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-route-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-route-guard.py"

echo "Running Pattern 93 regression tests..."

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
assert 'routes' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'total_routes' in s
assert 'default_route_count' in s
assert isinstance(s['default_gateways'], list)
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked /proc/net/route files
python3 -c "
import sys, tempfile, os
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-route-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    mock_route = os.path.join(tmp_dir, 'route')

    # Case 1: Healthy routing table (1 default route, 1 subnet route)
    # Destination 00000000 = 0.0.0.0, Gateway 0100A8C0 = 192.168.0.1, Flags 0003 = RTF_UP | RTF_GATEWAY
    # Destination 0000A8C0 = 192.168.0.0, Gateway 00000000 = 0.0.0.0, Flags 0001 = RTF_UP
    with open(mock_route, 'w') as f:
        f.write('Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n')
        f.write('eth0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n')
        f.write('eth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n')

    res = mod.audit_route(route_path=mock_route)
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['total_routes'] == 2
    assert s['default_route_count'] == 1
    assert '192.168.0.1' in s['default_gateways']

    # Case 2: Critical when default route is missing
    with open(mock_route, 'w') as f:
        f.write('Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n')
        f.write('eth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n')

    res_no_gw = mod.audit_route(route_path=mock_route)
    assert res_no_gw['summary']['status'] == 'CRITICAL'
    assert any('No active default route' in iss for iss in res_no_gw['summary']['issues'])

    # Case 3: Warning on route bloat
    with open(mock_route, 'w') as f:
        f.write('Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n')
        f.write('eth0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n')
        for i in range(120):
            f.write(f'eth0\t00000001\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n')

    res_bloat = mod.audit_route(route_path=mock_route, warn_routes=100, crit_routes=500)
    assert res_bloat['summary']['status'] == 'WARNING'
    assert any('Elevated route count' in iss for iss in res_bloat['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 93 tests passed!"
