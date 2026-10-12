#!/usr/bin/env bash
# tests/fm-jev-ipv6-route-gc-guard.test.sh - Regression tests for Pattern 281 (Ipv6RouteGcGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-route-gc-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-route-gc-guard.py"

echo "Running Pattern 281 regression tests..."

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
assert isinstance(data['gc_elasticity'], int)
assert isinstance(data['gc_interval_sec'], int)
assert isinstance(data['gc_timeout_sec'], int)
assert isinstance(data['gc_min_interval_ms'], int)
assert isinstance(data['mtu_expires_sec'], int)
assert isinstance(data['skip_notify_on_dev_down'], int)
assert isinstance(data['in_receives'], int)
assert isinstance(data['out_requests'], int)
assert isinstance(data['in_no_routes'], int)
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
mod = import_module('fm-jev-ipv6-route-gc-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    route_dir = d / 'route'
    route_dir.mkdir()
    (route_dir / 'gc_elasticity').write_text('9\n')
    (route_dir / 'gc_interval').write_text('30\n')
    (route_dir / 'gc_timeout').write_text('60\n')
    (route_dir / 'gc_min_interval_ms').write_text('500\n')
    (route_dir / 'mtu_expires').write_text('600\n')
    (route_dir / 'skip_notify_on_dev_down').write_text('0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text(
        'Ip6InReceives 1000\n'
        'Ip6OutRequests 1000\n'
        'Ip6InNoRoutes 0\n'
        'Ip6OutNoRoutes 0\n'
        'Ip6InDiscards 0\n'
        'Ip6OutDiscards 0\n'
    )

    res = mod.audit_ipv6_route_gc_guard(route_dir=str(route_dir), snmp6_file=str(snmp6_file))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['gc_interval_sec'] == 30
    assert res['gc_timeout_sec'] == 60
    assert res['skip_notify_on_dev_down'] == 0

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    route_dir = d / 'route'
    route_dir.mkdir()
    (route_dir / 'gc_elasticity').write_text('0\n')
    (route_dir / 'gc_interval').write_text('2\n')
    (route_dir / 'gc_timeout').write_text('5\n')
    (route_dir / 'gc_min_interval_ms').write_text('500\n')
    (route_dir / 'mtu_expires').write_text('20\n')
    (route_dir / 'skip_notify_on_dev_down').write_text('1\n')

    res = mod.audit_ipv6_route_gc_guard(route_dir=str(route_dir), snmp6_file=str(d / 'nonexistent'))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('skip_notify_on_dev_down is enabled' in iss for iss in res['issues'])
    assert any('Excessively aggressive IPv6 route gc_interval' in iss for iss in res['issues'])
    assert any('Abnormally short IPv6 route gc_timeout' in iss for iss in res['issues'])
    assert any('Abnormally short PMTU exception cache lifetime' in iss for iss in res['issues'])
    assert any('Invalid gc_elasticity' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 281 regression tests passed!"
