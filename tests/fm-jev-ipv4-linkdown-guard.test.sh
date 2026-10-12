#!/usr/bin/env bash
# tests/fm-jev-ipv4-linkdown-guard.test.sh - Regression tests for Pattern 298 (Ipv4LinkdownGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv4-linkdown-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv4-linkdown-guard.py"

echo "Running Pattern 298 regression tests..."

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
assert data['pattern'] == 298
assert data['name'] == 'ipv4_linkdown'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['all_bc_forwarding'], int)
assert isinstance(data['default_bc_forwarding'], int)
assert isinstance(data['all_route_localnet'], int)
assert isinstance(data['default_route_localnet'], int)
assert isinstance(data['all_accept_local'], int)
assert isinstance(data['default_accept_local'], int)
assert isinstance(data['bc_forwarding_enabled_count'], int)
assert isinstance(data['route_localnet_exposed_count'], int)
assert isinstance(data['accept_local_exposed_count'], int)
assert isinstance(data['in_receives'], int)
assert isinstance(data['forw_datagrams'], int)
assert isinstance(data['in_addr_errors'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['in_no_routes'], int)
assert isinstance(data['out_discards'], int)
assert isinstance(data['out_no_routes'], int)
assert isinstance(data['issues'], list)
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
mod = import_module('fm-jev-ipv4-linkdown-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'conf'
    conf.mkdir()

    for iface in ('all', 'default', 'eth0'):
        idir = conf / iface
        idir.mkdir()
        (idir / 'ignore_routes_with_linkdown').write_text('0\n')
        (idir / 'forwarding').write_text('0\n')
        (idir / 'mc_forwarding').write_text('0\n')
        (idir / 'bc_forwarding').write_text('0\n')
        (idir / 'accept_local').write_text('0\n')
        (idir / 'route_localnet').write_text('0\n')

    snmp = d / 'snmp'
    snmp.write_text(
        'Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes\n'
        'Ip: 0 64 1000 0 0 0 0 0 1000 800 0 0\n'
    )

    res = mod.evaluate_ipv4_linkdown(
        conf_dir=str(conf),
        snmp_path=str(snmp),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['interfaces_audited'] == 3
    assert res['bc_forwarding_enabled_count'] == 0
    assert res['route_localnet_exposed_count'] == 0
    assert res['accept_local_exposed_count'] == 0
    assert res['in_receives'] == 1000
    assert len(res['issues']) == 0

    # Test error cases: enabled bc_forwarding, enabled route_localnet, enabled accept_local
    (conf / 'eth0' / 'bc_forwarding').write_text('1\n')
    (conf / 'eth0' / 'route_localnet').write_text('1\n')
    (conf / 'eth0' / 'accept_local').write_text('1\n')

    res_err = mod.evaluate_ipv4_linkdown(
        conf_dir=str(conf),
        snmp_path=str(snmp),
    )
    assert res_err['healthy'] is False
    assert res_err['status'] == 'WARNING'
    assert any('bc_forwarding=1' in iss for iss in res_err['issues'])
    assert any('route_localnet enabled' in iss for iss in res_err['issues'])
    assert any('accept_local enabled' in iss for iss in res_err['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 298 tests passed successfully!"
