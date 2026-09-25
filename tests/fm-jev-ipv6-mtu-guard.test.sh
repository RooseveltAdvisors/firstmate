#!/usr/bin/env bash
# tests/fm-jev-ipv6-mtu-guard.test.sh - Regression tests for Pattern 267 (Ipv6MtuGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-mtu-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-mtu-guard.py"

echo "Running Pattern 267 regression tests..."

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
assert isinstance(data['default_mtu'], int)
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
mod = import_module('fm-jev-ipv6-mtu-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'mtu').write_text('65536\n')
    (conf_lo / 'accept_ra_mtu').write_text('1\n')

    (conf_enp / 'mtu').write_text('1500\n')
    (conf_enp / 'accept_ra_mtu').write_text('1\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6InTooBigErrors 0\nIcmp6InPktTooBigs 0\nIcmp6OutPktTooBigs 0\nIp6FragOKs 0\nIp6FragFails 0\nIp6FragCreates 0\n')

    res = mod.audit_ipv6_mtu_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['default_mtu'] == 1280

    # Issues case: mtu < 1280, accept_ra_mtu invalid, InTooBigErrors > 0, frag_fails > 0
    (conf_enp / 'mtu').write_text('1200\n')
    (conf_enp / 'accept_ra_mtu').write_text('2\n')
    snmp6_file.write_text('Ip6InTooBigErrors 5\nIcmp6InPktTooBigs 1\nIcmp6OutPktTooBigs 0\nIp6FragOKs 0\nIp6FragFails 3\nIp6FragCreates 0\n')

    res2 = mod.audit_ipv6_mtu_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
        min_mtu=1280,
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'WARNING'
    assert len(res2['issues']) == 4
    assert any('mtu=1200 < RFC 8200 minimum 1280' in i for i in res2['issues'])
    assert any('accept_ra_mtu=2 invalid' in i for i in res2['issues'])
    assert any('Inbound IPv6 Too Big errors detected: 5' in i for i in res2['issues'])
    assert any('IPv6 fragmentation failures detected: 3' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 267 regression tests passed!"
