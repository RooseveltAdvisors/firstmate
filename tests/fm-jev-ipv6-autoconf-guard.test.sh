#!/usr/bin/env bash
# tests/fm-jev-ipv6-autoconf-guard.test.sh - Regression tests for Pattern 286 (Ipv6AutoconfGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-autoconf-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-autoconf-guard.py"

echo "Running Pattern 286 regression tests..."

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
assert isinstance(data['all_autoconf'], int)
assert isinstance(data['default_max_addresses'], int)
assert isinstance(data['all_accept_ra_pinfo'], int)
assert isinstance(data['default_temp_valid_lft_sec'], int)
assert isinstance(data['default_temp_prefered_lft_sec'], int)
assert isinstance(data['default_use_tempaddr'], int)
assert isinstance(data['default_max_desync_factor_sec'], int)
assert isinstance(data['default_regen_max_retry'], int)
assert isinstance(data['in_addr_errors'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['in_router_advertisements'], int)
assert isinstance(data['slaac_compliant'], bool)
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
mod = import_module('fm-jev-ipv6-autoconf-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'autoconf').write_text('1\n')
    (eth0 / 'max_addresses').write_text('16\n')
    (eth0 / 'accept_ra_pinfo').write_text('1\n')
    (eth0 / 'use_tempaddr').write_text('2\n')
    (eth0 / 'temp_valid_lft').write_text('604800\n')
    (eth0 / 'temp_prefered_lft').write_text('86400\n')
    (eth0 / 'max_desync_factor').write_text('600\n')
    (eth0 / 'regen_max_retry').write_text('3\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6InAddrErrors 0\nIp6InDiscards 10\nIcmp6InRouterAdvertisements 2\nIcmp6InErrors 0\nIcmp6InCsumErrors 0\n')

    res = mod.audit_ipv6_autoconf_guard(conf_dir=str(conf_dir), snmp6_path=str(snmp6_file))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 1
    assert res['in_addr_errors'] == 0
    assert res['in_router_advertisements'] == 2

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'autoconf').write_text('1\n')
    (eth0 / 'max_addresses').write_text('0\n')
    (eth0 / 'accept_ra_pinfo').write_text('1\n')
    (eth0 / 'use_tempaddr').write_text('2\n')
    (eth0 / 'temp_valid_lft').write_text('500\n')
    (eth0 / 'temp_prefered_lft').write_text('600\n')
    (eth0 / 'max_desync_factor').write_text('600\n')
    (eth0 / 'regen_max_retry').write_text('0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6InAddrErrors 105\nIp6InDiscards 0\nIcmp6InRouterAdvertisements 0\nIcmp6InErrors 1\nIcmp6InCsumErrors 3\n')

    res = mod.audit_ipv6_autoconf_guard(conf_dir=str(conf_dir), snmp6_path=str(snmp6_file))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('preferred lifetime (600s) exceeds valid lifetime (500s)' in iss for iss in res['issues'])
    assert any('max_addresses=0' in iss for iss in res['issues'])
    assert any('regen_max_retry=0' in iss for iss in res['issues'])
    assert any('Elevated IPv6 inbound address errors' in iss for iss in res['issues'])
    assert any('ICMPv6 checksum errors detected' in iss for iss in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All 6/6 Pattern 286 tests passed successfully!"
