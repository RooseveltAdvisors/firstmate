#!/usr/bin/env bash
# tests/fm-jev-ipv6-dad-policy-guard.test.sh - Regression tests for Pattern 295 (Ipv6DadPolicyGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-dad-policy-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-dad-policy-guard.py"

echo "Running Pattern 295 regression tests..."

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
assert data['pattern'] == 295
assert data['name'] == 'ipv6_dad_policy'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['all_accept_dad'], int)
assert isinstance(data['default_accept_dad'], int)
assert isinstance(data['all_dad_transmits'], int)
assert isinstance(data['default_dad_transmits'], int)
assert isinstance(data['all_enhanced_dad'], int)
assert isinstance(data['default_enhanced_dad'], int)
assert isinstance(data['in_neighbor_solicits'], int)
assert isinstance(data['out_neighbor_solicits'], int)
assert isinstance(data['in_neighbor_advertisements'], int)
assert isinstance(data['out_neighbor_advertisements'], int)
assert isinstance(data['in_addr_errors'], int)
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
mod = import_module('fm-jev-ipv6-dad-policy-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'conf'
    conf.mkdir()

    for iface in ('all', 'default', 'eth0'):
        idir = conf / iface
        idir.mkdir()
        (idir / 'accept_dad').write_text('1\n')
        (idir / 'dad_transmits').write_text('1\n')
        (idir / 'enhanced_dad').write_text('1\n')
        (idir / 'keep_addr_on_down').write_text('0\n')

    snmp6 = d / 'snmp6'
    snmp6.write_text(
        'Icmp6InNeighborSolicits 5\n'
        'Icmp6OutNeighborSolicits 10\n'
        'Icmp6InNeighborAdvertisements 2\n'
        'Icmp6OutNeighborAdvertisements 2\n'
        'Ip6InAddrErrors 0\n'
    )

    res = mod.evaluate_ipv6_dad_policy(
        conf_dir=str(conf),
        snmp6_path=str(snmp6),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['interfaces_audited'] == 3
    assert res['all_accept_dad'] == 1
    assert res['default_dad_transmits'] == 1
    assert res['all_enhanced_dad'] == 1
    assert res['in_neighbor_solicits'] == 5
    assert len(res['issues']) == 0

    # Test error cases: disabled DAD on physical interface, invalid values
    (conf / 'eth0' / 'accept_dad').write_text('0\n')
    (conf / 'eth0' / 'enhanced_dad').write_text('5\n')
    (conf / 'eth0' / 'dad_transmits').write_text('-5\n')

    res_bad = mod.evaluate_ipv6_dad_policy(
        conf_dir=str(conf),
        snmp6_path=str(snmp6),
    )
    assert res_bad['healthy'] is False
    assert res_bad['status'] == 'DEGRADED'
    assert any('accept_dad=0' in iss for iss in res_bad['issues'])
    assert any('enhanced_dad=5 invalid' in iss for iss in res_bad['issues'])
    assert any('dad_transmits=-5 invalid' in iss for iss in res_bad['issues'])
"
echo "ok - unit tests with mocked files pass"

echo "All Pattern 295 tests passed successfully."
