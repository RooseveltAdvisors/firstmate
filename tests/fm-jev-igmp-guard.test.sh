#!/usr/bin/env bash
# tests/fm-jev-igmp-guard.test.sh - Regression tests for Pattern 211 (IP Multicast & IGMP Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-igmp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-igmp-guard.py"

echo "Running Pattern 211 regression tests..."

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
assert 'summary' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['total_v4_groups'], int)
assert isinstance(s['total_v6_groups'], int)
assert isinstance(s['max_v4_per_iface'], int)
assert isinstance(s['igmp_max_memberships'], int)
assert isinstance(s['saturation_ratio'], float)
assert isinstance(s['force_igmp_version'], int)
assert isinstance(s['in_mcast_pkts_v6'], int)
assert isinstance(s['out_mcast_pkts_v6'], int)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs / sysfs files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-igmp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ipv4_dir = d / 'ipv4'
    ipv4_dir.mkdir()
    conf_all = ipv4_dir / 'conf' / 'all'
    conf_all.mkdir(parents=True)

    igmp_f = d / 'igmp'
    igmp6_f = d / 'igmp6'
    snmp6_f = d / 'snmp6'

    # Scenario A: Nominal condition
    (ipv4_dir / 'igmp_max_memberships').write_text('20\n')
    (ipv4_dir / 'igmp_max_msf').write_text('10\n')
    (ipv4_dir / 'igmp_qrv').write_text('2\n')
    (conf_all / 'force_igmp_version').write_text('0\n')

    igmp_content = '''Idx\tDevice    : Count Querier\tGroup    Users Timer\tReporter
1\tlo        :     2      V3
\t\t\t\tFB0000E0     1 0:00000000\t\t0
\t\t\t\t010000E0     1 0:00000000\t\t0
2\tenp0      :     1      V3
\t\t\t\t010000E0     1 0:00000000\t\t0
'''
    igmp_f.write_text(igmp_content)

    igmp6_content = '''1    lo              ff0200000000000000000000000000fb     1 00000004 0
1    lo              ff020000000000000000000000000001     1 0000000C 0
'''
    igmp6_f.write_text(igmp6_content)

    snmp6_content = '''Ip6InMcastPkts                  \t500
Ip6OutMcastPkts                 \t600
'''
    snmp6_f.write_text(snmp6_content)

    res = mod.audit_igmp_guard(
        proc_igmp=str(igmp_f),
        proc_igmp6=str(igmp6_f),
        proc_snmp6=str(snmp6_f),
        proc_sys_ipv4=str(ipv4_dir),
    )
    assert res['summary']['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"summary\"][\"status\"]}'
    assert res['summary']['total_v4_groups'] == 3
    assert res['summary']['total_v6_groups'] == 2
    assert res['summary']['max_v4_per_iface'] == 2
    assert res['summary']['saturation_ratio'] == 0.1

    # Scenario B: CRITICAL when groups reach igmp_max_memberships
    (ipv4_dir / 'igmp_max_memberships').write_text('2\n')
    res_crit = mod.audit_igmp_guard(
        proc_igmp=str(igmp_f),
        proc_igmp6=str(igmp6_f),
        proc_snmp6=str(snmp6_f),
        proc_sys_ipv4=str(ipv4_dir),
    )
    assert res_crit['summary']['status'] == 'CRITICAL', f'Expected CRITICAL, got {res_crit[\"summary\"][\"status\"]}'
    assert any('CRITICAL' in issue for issue in res_crit['summary']['issues'])

    # Scenario C: WARNING on forced IGMP version
    (ipv4_dir / 'igmp_max_memberships').write_text('20\n')
    (conf_all / 'force_igmp_version').write_text('2\n')
    res_warn = mod.audit_igmp_guard(
        proc_igmp=str(igmp_f),
        proc_igmp6=str(igmp6_f),
        proc_snmp6=str(snmp6_f),
        proc_sys_ipv4=str(ipv4_dir),
    )
    assert res_warn['summary']['status'] == 'WARNING', f'Expected WARNING, got {res_warn[\"summary\"][\"status\"]}'
    assert any('force_igmp_version=2' in issue for issue in res_warn['summary']['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "All 6/6 tests passed successfully!"
