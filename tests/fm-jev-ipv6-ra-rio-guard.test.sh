#!/usr/bin/env bash
# tests/fm-jev-ipv6-ra-rio-guard.test.sh - Regression tests for Pattern 291 (Ipv6RaRioGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-ra-rio-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-ra-rio-guard.py"

echo "Running Pattern 291 regression tests..."

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
assert data['pattern'] == 291
assert data['name'] == 'ipv6_ra_rio'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['all_accept_ra_rt_info_min_plen'], int)
assert isinstance(data['all_accept_ra_rt_info_max_plen'], int)
assert isinstance(data['default_accept_ra_rt_info_min_plen'], int)
assert isinstance(data['default_accept_ra_rt_info_max_plen'], int)
assert isinstance(data['default_accept_ra_min_lft'], int)
assert isinstance(data['in_router_advertisements'], int)
assert isinstance(data['out_router_advertisements'], int)
assert isinstance(data['in_no_routes'], int)
assert isinstance(data['out_no_routes'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['out_discards'], int)
assert isinstance(data['icmp6_in_errors'], int)
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
mod = import_module('fm-jev-ipv6-ra-rio-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'accept_ra_rt_info_min_plen').write_text('0\n')
    (eth0 / 'accept_ra_rt_info_max_plen').write_text('0\n')
    (eth0 / 'accept_ra_min_lft').write_text('0\n')
    (eth0 / 'ra_honor_pio_life').write_text('0\n')
    (eth0 / 'ra_honor_pio_pflag').write_text('0\n')

    all_d = conf_dir / 'all'
    all_d.mkdir()
    (all_d / 'accept_ra_rt_info_min_plen').write_text('0\n')
    (all_d / 'accept_ra_rt_info_max_plen').write_text('0\n')
    (all_d / 'accept_ra_min_lft').write_text('0\n')
    (all_d / 'ra_honor_pio_life').write_text('0\n')
    (all_d / 'ra_honor_pio_pflag').write_text('0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Icmp6InRouterAdvertisements 0\nIcmp6OutRouterAdvertisements 0\nIp6InNoRoutes 0\nIp6OutNoRoutes 0\nIp6InDiscards 0\nIp6OutDiscards 0\nIcmp6InErrors 0\n')

    res = mod.evaluate_ra_rio_policy(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['all_accept_ra_rt_info_min_plen'] == 0
    assert res['all_accept_ra_rt_info_max_plen'] == 0

# Test degraded case with invalid prefix bound
with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'accept_ra_rt_info_min_plen').write_text('96\n')
    (eth0 / 'accept_ra_rt_info_max_plen').write_text('64\n')
    (eth0 / 'accept_ra_min_lft').write_text('0\n')
    (eth0 / 'ra_honor_pio_life').write_text('0\n')
    (eth0 / 'ra_honor_pio_pflag').write_text('0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('')

    res = mod.evaluate_ra_rio_policy(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is False
    assert res['status'] == 'DEGRADED'
    assert any('conflicting prefix bounds' in i for i in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 291 regression tests passed successfully."
