#!/usr/bin/env bash
# tests/fm-jev-router-solicit-guard.test.sh - Regression tests for Pattern 260 (RouterSolicitGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-router-solicit-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-router-solicit-guard.py"

echo "Running Pattern 260 regression tests..."

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
mod = import_module('fm-jev-router-solicit-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'router_solicitations').write_text('-1\n')
    (conf_lo / 'router_solicitation_interval').write_text('4\n')
    (conf_lo / 'router_solicitation_delay').write_text('1\n')
    (conf_lo / 'router_solicitation_max_interval').write_text('3600\n')
    (conf_enp / 'router_solicitations').write_text('3\n')
    (conf_enp / 'router_solicitation_interval').write_text('4\n')
    (conf_enp / 'router_solicitation_delay').write_text('1\n')
    (conf_enp / 'router_solicitation_max_interval').write_text('3600\n')
    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Icmp6InRouterSolicits 0\nIcmp6OutRouterSolicits 10\nIcmp6InRouterAdvertisements 5\nIcmp6OutRouterAdvertisements 0\n')

    res = mod.audit_router_solicit_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['out_router_solicits'] == 10

    # Issues case: active sol on lo, 0 interval, 0 delay on enp
    (conf_lo / 'router_solicitations').write_text('3\n')
    (conf_lo / 'router_solicitation_interval').write_text('0\n')
    (conf_lo / 'router_solicitation_delay').write_text('1\n')
    (conf_enp / 'router_solicitations').write_text('3\n')
    (conf_enp / 'router_solicitation_interval').write_text('0\n')
    (conf_enp / 'router_solicitation_delay').write_text('0\n')
    snmp6_file.write_text('Icmp6InRouterSolicits 0\nIcmp6OutRouterSolicits 10\nIcmp6InRouterAdvertisements 0\nIcmp6OutRouterAdvertisements 0\n')

    res2 = mod.audit_router_solicit_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'WARNING'
    assert len(res2['issues']) == 3
    assert any('Loopback interface has active router solicitations enabled' in i for i in res2['issues'])
    assert any('Aggressive Router Solicitation interval' in i for i in res2['issues'])
    assert any('Zero initial delay before Router Solicitation' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 260 regression tests passed!"
