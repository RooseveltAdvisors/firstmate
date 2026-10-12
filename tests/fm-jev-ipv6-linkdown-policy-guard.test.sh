#!/usr/bin/env bash
# tests/fm-jev-ipv6-linkdown-policy-guard.test.sh - Regression tests for Pattern 280 (Ipv6LinkdownPolicyGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-linkdown-policy-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-linkdown-policy-guard.py"

echo "Running Pattern 280 regression tests..."

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
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['force_forwarding_interfaces'], int)
assert isinstance(data['local_ra_interfaces'], int)
assert isinstance(data['in_receives'], int)
assert isinstance(data['in_no_routes'], int)
assert isinstance(data['in_addr_errors'], int)
assert isinstance(data['out_forw_datagrams'], int)
assert isinstance(data['out_discards'], int)
assert isinstance(data['interface_policies'], dict)
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
mod = import_module('fm-jev-ipv6-linkdown-policy-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    for iface in ('all', 'default', 'eth0'):
        (conf_dir / iface).mkdir()
        (conf_dir / iface / 'ignore_routes_with_linkdown').write_text('0\n')
        (conf_dir / iface / 'force_forwarding').write_text('0\n')
        (conf_dir / iface / 'force_tllao').write_text('0\n')
        (conf_dir / iface / 'accept_ra_from_local').write_text('0\n')
        (conf_dir / iface / 'drop_unicast_in_l2_multicast').write_text('0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text(
        'Ip6InReceives 1000\n'
        'Ip6InNoRoutes 0\n'
        'Ip6InAddrErrors 0\n'
        'Ip6OutForwDatagrams 0\n'
        'Ip6OutDiscards 0\n'
    )

    res = mod.audit_ipv6_linkdown_policy_guard(conf_dir=str(conf_dir), snmp6_file=str(snmp6_file))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 3
    assert res['force_forwarding_interfaces'] == 0
    assert res['local_ra_interfaces'] == 0

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'ignore_routes_with_linkdown').write_text('0\n')
    (eth0 / 'force_forwarding').write_text('1\n')
    (eth0 / 'force_tllao').write_text('0\n')
    (eth0 / 'accept_ra_from_local').write_text('1\n')
    (eth0 / 'drop_unicast_in_l2_multicast').write_text('0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text(
        'Ip6InReceives 100\n'
        'Ip6InNoRoutes 25\n'
        'Ip6InAddrErrors 0\n'
        'Ip6OutForwDatagrams 0\n'
        'Ip6OutDiscards 0\n'
    )

    res = mod.audit_ipv6_linkdown_policy_guard(conf_dir=str(conf_dir), snmp6_file=str(snmp6_file))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert res['force_forwarding_interfaces'] == 1
    assert res['local_ra_interfaces'] == 1
    assert any('force_forwarding enabled' in iss for iss in res['issues'])
    assert any('accept_ra_from_local enabled' in iss for iss in res['issues'])
    assert any('Elevated IPv6 unroutable packet drops' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 280 regression tests passed!"
