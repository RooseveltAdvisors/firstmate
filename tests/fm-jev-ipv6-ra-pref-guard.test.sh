#!/usr/bin/env bash
# tests/fm-jev-ipv6-ra-pref-guard.test.sh - Regression tests for Pattern 294 (Ipv6RaPrefGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-ra-pref-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-ra-pref-guard.py"

echo "Running Pattern 294 regression tests..."

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
assert data['pattern'] == 294
assert data['name'] == 'ipv6_ra_pref'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['all_accept_ra_rtr_pref'], int)
assert isinstance(data['default_accept_ra_rtr_pref'], int)
assert isinstance(data['all_accept_ra_defrtr'], int)
assert isinstance(data['default_accept_ra_defrtr'], int)
assert isinstance(data['default_router_probe_interval_sec'], int)
assert isinstance(data['in_router_advertisements'], int)
assert isinstance(data['out_router_advertisements'], int)
assert isinstance(data['in_router_solicits'], int)
assert isinstance(data['out_router_solicits'], int)
assert isinstance(data['in_no_routes'], int)
assert isinstance(data['out_no_routes'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['out_discards'], int)
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
mod = import_module('fm-jev-ipv6-ra-pref-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'conf'
    conf.mkdir()

    for iface in ('all', 'default', 'eth0'):
        idir = conf / iface
        idir.mkdir()
        (idir / 'accept_ra_rtr_pref').write_text('1\n')
        (idir / 'accept_ra_defrtr').write_text('1\n')
        (idir / 'router_probe_interval').write_text('60\n')
        (idir / 'accept_ra_from_local').write_text('0\n')

    snmp6 = d / 'snmp6'
    snmp6.write_text(
        'Icmp6InRouterAdvertisements 10\n'
        'Icmp6OutRouterAdvertisements 0\n'
        'Icmp6InRouterSolicits 0\n'
        'Icmp6OutRouterSolicits 5\n'
        'Ip6InNoRoutes 0\n'
        'Ip6OutNoRoutes 100\n'
        'Ip6InDiscards 2\n'
        'Ip6OutDiscards 0\n'
    )

    res = mod.evaluate_ipv6_ra_pref_policy(
        conf_dir=str(conf),
        snmp6_path=str(snmp6),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['interfaces_audited'] == 3
    assert res['all_accept_ra_rtr_pref'] == 1
    assert res['default_accept_ra_defrtr'] == 1
    assert res['default_router_probe_interval_sec'] == 60
    assert res['in_router_advertisements'] == 10
    assert res['out_router_solicits'] == 5
    assert len(res['issues']) == 0

    # Test error cases: loopback local RA enabled and invalid probe interval
    (conf / 'eth0' / 'accept_ra_from_local').write_text('1\n')
    (conf / 'eth0' / 'router_probe_interval').write_text('0\n')
    (conf / 'eth0' / 'accept_ra_rtr_pref').write_text('3\n')

    res_bad = mod.evaluate_ipv6_ra_pref_policy(
        conf_dir=str(conf),
        snmp6_path=str(snmp6),
    )
    assert res_bad['healthy'] is False
    assert res_bad['status'] == 'DEGRADED'
    assert any('accept_ra_from_local=1' in iss for iss in res_bad['issues'])
    assert any('router_probe_interval=0s invalid' in iss for iss in res_bad['issues'])
    assert any('accept_ra_rtr_pref=3 invalid' in iss for iss in res_bad['issues'])
"
echo "ok - unit tests with mocked files pass"

echo "All Pattern 294 tests passed successfully."
