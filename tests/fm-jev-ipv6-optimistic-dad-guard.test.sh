#!/usr/bin/env bash
# tests/fm-jev-ipv6-optimistic-dad-guard.test.sh - Regression tests for Pattern 288 (Ipv6OptimisticDadGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-optimistic-dad-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-optimistic-dad-guard.py"

echo "Running Pattern 288 regression tests..."

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
assert isinstance(data['all_optimistic_dad'], int)
assert isinstance(data['default_optimistic_dad'], int)
assert isinstance(data['all_use_optimistic'], int)
assert isinstance(data['default_use_optimistic'], int)
assert isinstance(data['default_regen_min_advance_sec'], int)
assert isinstance(data['all_disable_policy'], int)
assert isinstance(data['out_neighbor_solicits'], int)
assert isinstance(data['in_addr_errors'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['in_csum_errors'], int)
assert isinstance(data['dad_policy_compliant'], bool)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
assert isinstance(data['interfaces'], dict)
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
mod = import_module('fm-jev-ipv6-optimistic-dad-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'optimistic_dad').write_text('0\n')
    (eth0 / 'use_optimistic').write_text('0\n')
    (eth0 / 'regen_min_advance').write_text('2\n')
    (eth0 / 'disable_policy').write_text('0\n')

    all_d = conf_dir / 'all'
    all_d.mkdir()
    (all_d / 'optimistic_dad').write_text('0\n')
    (all_d / 'use_optimistic').write_text('0\n')
    (all_d / 'regen_min_advance').write_text('2\n')
    (all_d / 'disable_policy').write_text('0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Icmp6OutNeighborSolicits 50\nIp6InAddrErrors 0\nIp6InDiscards 0\nIcmp6InErrors 0\nIcmp6InCsumErrors 0\n')

    res = mod.audit_ipv6_optimistic_dad_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['all_optimistic_dad'] == 0
    assert res['all_use_optimistic'] == 0
    assert res['out_neighbor_solicits'] == 50

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'optimistic_dad').write_text('2\n')
    (eth0 / 'use_optimistic').write_text('5\n')
    (eth0 / 'regen_min_advance').write_text('0\n')
    (eth0 / 'disable_policy').write_text('1\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Icmp6OutNeighborSolicits 10\nIp6InAddrErrors 150\nIp6InDiscards 0\nIcmp6InErrors 0\nIcmp6InCsumErrors 3\n')

    res = mod.audit_ipv6_optimistic_dad_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('invalid optimistic_dad' in iss for iss in res['issues'])
    assert any('invalid use_optimistic' in iss for iss in res['issues'])
    assert any('regen_min_advance (0s) is below minimum threshold' in iss for iss in res['issues'])
    assert any('IPsec security policy check disabled' in iss for iss in res['issues'])
    assert any('Elevated IPv6 inbound address errors' in iss for iss in res['issues'])
    assert any('ICMPv6 checksum errors detected' in iss for iss in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All 6/6 Pattern 288 tests passed successfully!"
