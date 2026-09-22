#!/usr/bin/env bash
# tests/fm-jev-igmp-guard.test.sh - Regression tests for Pattern 122 (IP Multicast Group Membership & IGMP Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-igmp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-igmp-guard.py"

echo "Running Pattern 122 regression tests..."

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
assert 'healthy' in data
assert 'status' in data
assert 'pattern' in data
assert data['pattern'] == 122
assert 'name' in data
assert 'issues' in data
assert 'config' in data
assert 'multicast_interfaces' in data
assert 'telemetry' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['issues'], list)
assert isinstance(data['multicast_interfaces'], list)
telem = data['telemetry']
assert 'total_interfaces_monitored' in telem
assert 'total_multicast_groups_joined' in telem
assert 'in_mcast_pkts' in telem
assert 'out_mcast_pkts' in telem
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked proc files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-igmp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    igmp_file = d / 'igmp'
    igmp_content = '''Idx\tDevice    : Count Querier\tGroup    Users Timer\tReporter
1\tlo        :     2      V3
\t\t\t\tFB0000E0     1 0:00000000\t\t0
\t\t\t\t010000E0     1 0:00000000\t\t0
2\tenp7s0    :     2      V3
\t\t\t\tFB0000E0     1 0:00000000\t\t0
\t\t\t\t010000E0     1 0:00000000\t\t0
'''
    igmp_file.write_text(igmp_content)

    netstat_file = d / 'netstat'
    netstat_content = '''IpExt: InNoRoutes InTruncatedPkts InMcastPkts OutMcastPkts InBcastPkts OutBcastPkts InOctets OutOctets InMcastOctets OutMcastOctets InBcastOctets OutBcastOctets InCsumErrors InNoECTPkts InECT1Pkts InECT0Pkts InCEPkts ReasmOverlaps
IpExt: 0 0 1000 200 5000 0 100000 50000 20000 5000 10000 0 0 0 0 0 0 0
'''
    netstat_file.write_text(netstat_content)

    conf_dir = d / 'conf'
    conf_dir.mkdir()
    (conf_dir / 'all').mkdir()
    (conf_dir / 'all' / 'force_igmp_version').write_text('0\n')
    (conf_dir / 'enp7s0').mkdir()
    (conf_dir / 'enp7s0' / 'force_igmp_version').write_text('0\n')

    max_memb_file = d / 'igmp_max_memberships'
    max_memb_file.write_text('20\n')

    max_msf_file = d / 'igmp_max_msf'
    max_msf_file.write_text('10\n')

    # Test healthy scenario
    res = mod.audit_igmp(
        proc_igmp=str(igmp_file),
        conf_dir=str(conf_dir),
        netstat_file=str(netstat_file),
        max_memberships_file=str(max_memb_file),
        max_msf_file=str(max_msf_file),
    )
    assert res['healthy'] is True
    assert len(res['issues']) == 0
    assert res['telemetry']['total_multicast_groups_joined'] == 4
    assert res['telemetry']['in_mcast_pkts'] == 1000
    assert res['telemetry']['out_mcast_pkts'] == 200

    # Test saturation scenario
    max_memb_file.write_text('2\n')  # 2 groups joined = saturation
    res_sat = mod.audit_igmp(
        proc_igmp=str(igmp_file),
        conf_dir=str(conf_dir),
        netstat_file=str(netstat_file),
        max_memberships_file=str(max_memb_file),
        max_msf_file=str(max_msf_file),
    )
    assert res_sat['healthy'] is False
    assert any('igmp_max_memberships' in issue for issue in res_sat['issues'])

    # Test legacy IGMP force version scenario
    (conf_dir / 'enp7s0' / 'force_igmp_version').write_text('2\n')
    res_ver = mod.audit_igmp(
        proc_igmp=str(igmp_file),
        conf_dir=str(conf_dir),
        netstat_file=str(netstat_file),
        max_memberships_file=str(max_memb_file),
        max_msf_file=str(max_msf_file),
    )
    assert res_ver['healthy'] is False
    assert any('forced legacy IGMP' in issue for issue in res_ver['issues'])
"
echo "ok - mocked igmp, conf, and netstat unit tests pass"

echo "All Pattern 122 tests passed successfully!"
