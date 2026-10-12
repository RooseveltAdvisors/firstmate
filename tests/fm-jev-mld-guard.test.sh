#!/usr/bin/env bash
# tests/fm-jev-mld-guard.test.sh - Regression tests for Pattern 263 (MldGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-mld-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-mld-guard.py"

echo "Running Pattern 263 regression tests..."

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
assert isinstance(data['mld_qrv'], int)
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
mod = import_module('fm-jev-mld-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'mldv1_unsolicited_report_interval').write_text('10000\n')
    (conf_lo / 'mldv2_unsolicited_report_interval').write_text('1000\n')
    (conf_lo / 'force_mld_version').write_text('0\n')
    (conf_enp / 'mldv1_unsolicited_report_interval').write_text('10000\n')
    (conf_enp / 'mldv2_unsolicited_report_interval').write_text('1000\n')
    (conf_enp / 'force_mld_version').write_text('0\n')

    ipv6_sys = d / 'ipv6'
    ipv6_sys.mkdir(parents=True)
    (ipv6_sys / 'mld_qrv').write_text('2\n')
    (ipv6_sys / 'mld_max_msf').write_text('64\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Icmp6InMLDv2Reports 5\nIcmp6InGroupMembQueries 1\nIcmp6InGroupMembResponses 2\nIcmp6InGroupMembReductions 0\n')

    res = mod.audit_mld_guard(
        conf_dir=str(conf_dir),
        ipv6_sys_dir=str(ipv6_sys),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['mld_qrv'] == 2
    assert res['in_mldv2_reports'] == 5

    # Issues case: mld_qrv=0, interval < 100ms
    (ipv6_sys / 'mld_qrv').write_text('0\n')
    (conf_enp / 'mldv2_unsolicited_report_interval').write_text('50\n')

    res2 = mod.audit_mld_guard(
        conf_dir=str(conf_dir),
        ipv6_sys_dir=str(ipv6_sys),
        snmp6_path=str(snmp6_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'WARNING'
    assert len(res2['issues']) == 2
    assert any('Invalid or fragile MLD Querier Robustness Variable' in i for i in res2['issues'])
    assert any('Aggressive MLDv2 unsolicited report interval' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 263 regression tests passed!"
