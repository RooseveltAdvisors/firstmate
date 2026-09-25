#!/usr/bin/env bash
# tests/fm-jev-ipv6-ra-pio-guard.test.sh - Regression tests for Pattern 301 (Ipv6RaPioGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-ra-pio-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-ra-pio-guard.py"

echo "Running Pattern 301 regression tests..."

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
assert data['pattern'] == 301
assert data['name'] == 'ipv6_ra_pio'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['all_ra_honor_pio_life'], int)
assert isinstance(data['default_ra_honor_pio_life'], int)
assert isinstance(data['all_ra_honor_pio_pflag'], int)
assert isinstance(data['all_ra_defrtr_metric'], int)
assert isinstance(data['all_accept_ra_pinfo'], int)
assert isinstance(data['in_router_advertisements'], int)
assert isinstance(data['out_router_solicits'], int)
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
mod = import_module('fm-jev-ipv6-ra-pio-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'conf'
    conf.mkdir()
    eth0 = conf / 'eth0'
    eth0.mkdir()
    (eth0 / 'ra_honor_pio_life').write_text('0\n')
    (eth0 / 'ra_honor_pio_pflag').write_text('0\n')
    (eth0 / 'ra_defrtr_metric').write_text('1024\n')
    (eth0 / 'accept_ra_pinfo').write_text('1\n')

    snmp = d / 'snmp6'
    snmp.write_text(
        'Icmp6InRouterAdvertisements 0\n'
        'Icmp6OutRouterAdvertisements 0\n'
        'Icmp6InRouterSolicits 0\n'
        'Icmp6OutRouterSolicits 10\n'
    )

    res = mod.evaluate_ipv6_ra_pio(
        conf_dir=str(conf),
        snmp6_file=str(snmp),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['interfaces_audited'] == 1
    assert len(res['issues']) == 0

    # Test error cases: invalid values
    (eth0 / 'ra_honor_pio_life').write_text('5\n')
    (eth0 / 'ra_honor_pio_pflag').write_text('-1\n')
    (eth0 / 'ra_defrtr_metric').write_text('0\n')
    (eth0 / 'accept_ra_pinfo').write_text('2\n')

    res_err = mod.evaluate_ipv6_ra_pio(
        conf_dir=str(conf),
        snmp6_file=str(snmp),
    )
    assert res_err['healthy'] is False
    assert res_err['status'] == 'WARNING'
    assert any('invalid ra_honor_pio_life' in iss for iss in res_err['issues'])
    assert any('invalid ra_defrtr_metric' in iss for iss in res_err['issues'])
    assert any('invalid accept_ra_pinfo' in iss for iss in res_err['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 301 tests passed successfully!"
