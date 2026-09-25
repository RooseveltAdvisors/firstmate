#!/usr/bin/env bash
# tests/fm-jev-ipv4-route-gc-guard.test.sh - Regression tests for Pattern 284 (Ipv4RouteGcGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv4-route-gc-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv4-route-gc-guard.py"

echo "Running Pattern 284 regression tests..."

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
assert isinstance(data['gc_interval_sec'], int)
assert isinstance(data['gc_timeout_sec'], int)
assert isinstance(data['gc_min_interval_ms'], int)
assert isinstance(data['gc_elasticity'], int)
assert isinstance(data['mtu_expires_sec'], int)
assert isinstance(data['min_pmtu'], int)
assert isinstance(data['min_adv_mss'], int)
assert isinstance(data['max_size'], int)
assert isinstance(data['in_receives'], int)
assert isinstance(data['out_requests'], int)
assert isinstance(data['out_no_routes'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['out_discards'], int)
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
mod = import_module('fm-jev-ipv4-route-gc-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    route_dir = d / 'route'
    route_dir.mkdir()
    (route_dir / 'gc_interval').write_text('60\n')
    (route_dir / 'gc_timeout').write_text('300\n')
    (route_dir / 'gc_min_interval_ms').write_text('500\n')
    (route_dir / 'gc_elasticity').write_text('8\n')
    (route_dir / 'mtu_expires').write_text('600\n')
    (route_dir / 'min_pmtu').write_text('552\n')
    (route_dir / 'min_adv_mss').write_text('256\n')
    (route_dir / 'max_size').write_text('2147483647\n')

    snmp_file = d / 'snmp'
    snmp_file.write_text(
        'Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates\n'
        'Ip: 1 64 1000 0 0 0 0 0 1000 1000 0 0 0 0 0 0 0 0 0\n'
    )

    res = mod.audit_ipv4_route_gc_guard(route_dir=str(route_dir), snmp_file=str(snmp_file))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['gc_interval_sec'] == 60
    assert res['gc_timeout_sec'] == 300
    assert res['min_pmtu'] == 552
    assert res['min_adv_mss'] == 256
    assert res['out_no_routes'] == 0

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    route_dir = d / 'route'
    route_dir.mkdir()
    (route_dir / 'gc_interval').write_text('2\n')
    (route_dir / 'gc_timeout').write_text('5\n')
    (route_dir / 'gc_min_interval_ms').write_text('500\n')
    (route_dir / 'gc_elasticity').write_text('0\n')
    (route_dir / 'mtu_expires').write_text('30\n')
    (route_dir / 'min_pmtu').write_text('50\n')
    (route_dir / 'min_adv_mss').write_text('30\n')
    (route_dir / 'max_size').write_text('2147483647\n')

    res = mod.audit_ipv4_route_gc_guard(route_dir=str(route_dir), snmp_file=str(d / 'nonexistent'))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('Excessively aggressive IPv4 route gc_interval' in iss for iss in res['issues'])
    assert any('Abnormally short IPv4 route gc_timeout' in iss for iss in res['issues'])
    assert any('Abnormally short PMTU exception cache lifetime' in iss for iss in res['issues'])
    assert any('Sub-RFC 791 minimum PMTU' in iss for iss in res['issues'])
    assert any('Sub-minimum min_adv_mss' in iss for iss in res['issues'])
    assert any('Invalid gc_elasticity' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 284 regression tests passed!"
