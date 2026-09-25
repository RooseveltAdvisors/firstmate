#!/usr/bin/env bash
# tests/fm-jev-ipv6-hop-limit-guard.test.sh - Regression tests for Pattern 266 (Ipv6HopLimitGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-hop-limit-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-hop-limit-guard.py"

echo "Running Pattern 266 regression tests..."

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
assert isinstance(data['default_hop_limit'], int)
assert isinstance(data['issues'], list)
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
mod = import_module('fm-jev-ipv6-hop-limit-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'hop_limit').write_text('64\n')
    (conf_lo / 'accept_ra_min_hop_limit').write_text('1\n')

    (conf_enp / 'hop_limit').write_text('64\n')
    (conf_enp / 'accept_ra_min_hop_limit').write_text('1\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6InReceives 100\nIp6InHdrErrors 0\nIp6InDelivers 100\nIp6OutRequests 90\nIcmp6InTimeExceeded 0\nIcmp6OutTimeExceeded 0\n')

    res = mod.audit_ipv6_hop_limit_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['default_hop_limit'] == 64

    # Issues case: hop_limit < 32 and min_ra_hop_limit < 1
    (conf_enp / 'hop_limit').write_text('16\n')
    (conf_enp / 'accept_ra_min_hop_limit').write_text('0\n')

    res2 = mod.audit_ipv6_hop_limit_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
        min_safe_hop_limit=32,
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'WARNING'
    assert len(res2['issues']) == 2
    assert any('hop_limit=16 below safe floor 32' in i for i in res2['issues'])
    assert any('accept_ra_min_hop_limit=0 < 1' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 266 regression tests passed!"
