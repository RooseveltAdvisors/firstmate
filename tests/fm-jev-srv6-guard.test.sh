#!/usr/bin/env bash
# tests/fm-jev-srv6-guard.test.sh - Regression tests for Pattern 257 (Srv6Guard — 300th Milestone)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-srv6-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-srv6-guard.py"

echo "Running Pattern 257 regression tests..."

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
assert isinstance(data['seg6_flowlabel'], int)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['enabled_interfaces_count'], int)
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
mod = import_module('fm-jev-srv6-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'seg6_enabled').write_text('0\n')
    (conf_lo / 'seg6_require_hmac').write_text('0\n')
    (conf_enp / 'seg6_enabled').write_text('0\n')
    (conf_enp / 'seg6_require_hmac').write_text('0\n')
    flowlabel_file = d / 'seg6_flowlabel'
    flowlabel_file.write_text('0\n')
    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6InReceives 10000\nIp6InHdrErrors 0\nIp6InTruncatedPkts 0\nIp6InDiscards 0\n')

    res = mod.audit_srv6_guard(
        enabled_glob=str(conf_dir / '*' / 'seg6_enabled'),
        hmac_glob=str(conf_dir / '*' / 'seg6_require_hmac'),
        flowlabel_path=str(flowlabel_file),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['seg6_flowlabel'] == 0
    assert res['enabled_interfaces_count'] == 0
    assert res['lo_seg6_enabled'] == 0

    # Issues case: enabled on lo, unauthenticated hmac, invalid flowlabel, high errors
    (conf_lo / 'seg6_enabled').write_text('1\n')
    (conf_lo / 'seg6_require_hmac').write_text('0\n')
    (conf_enp / 'seg6_enabled').write_text('1\n')
    (conf_enp / 'seg6_require_hmac').write_text('0\n')
    flowlabel_file.write_text('9\n')
    snmp6_file.write_text('Ip6InReceives 10000\nIp6InHdrErrors 100\nIp6InTruncatedPkts 0\nIp6InDiscards 0\n')

    res2 = mod.audit_srv6_guard(
        enabled_glob=str(conf_dir / '*' / 'seg6_enabled'),
        hmac_glob=str(conf_dir / '*' / 'seg6_require_hmac'),
        flowlabel_path=str(flowlabel_file),
        snmp6_path=str(snmp6_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'CRITICAL'
    assert len(res2['issues']) == 4
    assert any('Loopback interface has SRv6 enabled' in i for i in res2['issues'])
    assert any('without mandatory HMAC validation' in i for i in res2['issues'])
    assert any('Invalid net.ipv6.seg6_flowlabel' in i for i in res2['issues'])
    assert any('Critical IPv6 header error rate' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 257 regression tests passed!"
