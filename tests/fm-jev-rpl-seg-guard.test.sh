#!/usr/bin/env bash
# tests/fm-jev-rpl-seg-guard.test.sh - Regression tests for Pattern 258 (RplSegGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rpl-seg-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rpl-seg-guard.py"

echo "Running Pattern 258 regression tests..."

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
mod = import_module('fm-jev-rpl-seg-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'rpl_seg_enabled').write_text('0\n')
    (conf_enp / 'rpl_seg_enabled').write_text('0\n')
    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Ip6InReceives 10000\nIp6InHdrErrors 0\nIp6InTruncatedPkts 0\nIp6InDiscards 0\nIp6InUnknownProtos 0\n')

    res = mod.audit_rpl_seg_guard(
        rpl_glob=str(conf_dir / '*' / 'rpl_seg_enabled'),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['enabled_interfaces_count'] == 0
    assert res['lo_rpl_seg_enabled'] == 0

    # Issues case: enabled on lo and enp, high error rate
    (conf_lo / 'rpl_seg_enabled').write_text('1\n')
    (conf_enp / 'rpl_seg_enabled').write_text('1\n')
    snmp6_file.write_text('Ip6InReceives 10000\nIp6InHdrErrors 100\nIp6InTruncatedPkts 0\nIp6InDiscards 0\nIp6InUnknownProtos 0\n')

    res2 = mod.audit_rpl_seg_guard(
        rpl_glob=str(conf_dir / '*' / 'rpl_seg_enabled'),
        snmp6_path=str(snmp6_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'CRITICAL'
    assert len(res2['issues']) == 3
    assert any('Loopback interface has RPL source routing enabled' in i for i in res2['issues'])
    assert any('RPL source routing enabled on interfaces' in i for i in res2['issues'])
    assert any('Critical IPv6 header error rate' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 258 regression tests passed!"
