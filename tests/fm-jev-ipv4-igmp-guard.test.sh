#!/usr/bin/env bash
# tests/fm-jev-ipv4-igmp-guard.test.sh - Regression tests for Pattern 296 (Ipv4IgmpGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv4-igmp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv4-igmp-guard.py"

echo "Running Pattern 296 regression tests..."

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
assert data['pattern'] == 296
assert data['name'] == 'ipv4_igmp'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['igmp_qrv'], int)
assert isinstance(data['igmp_max_memberships'], int)
assert isinstance(data['igmp_max_msf'], int)
assert isinstance(data['all_force_igmp_version'], int)
assert isinstance(data['default_force_igmp_version'], int)
assert isinstance(data['default_igmpv2_interval_ms'], int)
assert isinstance(data['default_igmpv3_interval_ms'], int)
assert isinstance(data['in_mcast_pkts'], int)
assert isinstance(data['out_mcast_pkts'], int)
assert isinstance(data['in_bcast_pkts'], int)
assert isinstance(data['out_bcast_pkts'], int)
assert isinstance(data['active_igmp_groups'], int)
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
mod = import_module('fm-jev-ipv4-igmp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'conf'
    conf.mkdir()

    for iface in ('all', 'default', 'eth0'):
        idir = conf / iface
        idir.mkdir()
        (idir / 'force_igmp_version').write_text('0\n')
        (idir / 'igmpv2_unsolicited_report_interval').write_text('10000\n')
        (idir / 'igmpv3_unsolicited_report_interval').write_text('1000\n')

    sys_dir = d / 'ipv4'
    sys_dir.mkdir()
    (sys_dir / 'igmp_qrv').write_text('2\n')
    (sys_dir / 'igmp_max_memberships').write_text('20\n')
    (sys_dir / 'igmp_max_msf').write_text('10\n')

    igmp = d / 'igmp'
    igmp.write_text(
        'Idx\tDevice    : Count Querier\tGroup    Users Timer\tReporter\n'
        '1\tlo        :     2      V3\n'
        '\t\t\t\tFB0000E0     1 0:00000000\t\t0\n'
        '\t\t\t\t010000E0     1 0:00000000\t\t0\n'
        '2\teth0      :     1      V3\n'
        '\t\t\t\t010000E0     1 0:00000000\t\t0\n'
    )

    netstat = d / 'netstat'
    netstat.write_text(
        'TcpExt: SyncookiesSent\n'
        'TcpExt: 0\n'
        'IpExt: InNoRoutes InTruncatedPkts InMcastPkts OutMcastPkts InBcastPkts OutBcastPkts InOctets\n'
        'IpExt: 0 0 100 20 500 0 1000\n'
    )

    res = mod.evaluate_ipv4_igmp(
        conf_dir=str(conf),
        ipv4_sys_dir=str(sys_dir),
        igmp_path=str(igmp),
        netstat_path=str(netstat),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['interfaces_audited'] == 3
    assert res['igmp_qrv'] == 2
    assert res['igmp_max_memberships'] == 20
    assert res['igmp_max_msf'] == 10
    assert res['in_mcast_pkts'] == 100
    assert res['out_mcast_pkts'] == 20
    assert res['in_bcast_pkts'] == 500
    assert res['active_igmp_groups'] == 3
    assert len(res['issues']) == 0

    # Test error cases: forced IGMPv1, aggressive report interval, invalid QRV
    (conf / 'eth0' / 'force_igmp_version').write_text('1\n')
    (conf / 'eth0' / 'igmpv3_unsolicited_report_interval').write_text('10\n')
    (sys_dir / 'igmp_qrv').write_text('0\n')
    (sys_dir / 'igmp_max_memberships').write_text('2\n')
    (sys_dir / 'igmp_max_msf').write_text('1\n')

    res_err = mod.evaluate_ipv4_igmp(
        conf_dir=str(conf),
        ipv4_sys_dir=str(sys_dir),
        igmp_path=str(igmp),
        netstat_path=str(netstat),
    )
    assert res_err['healthy'] is False
    assert res_err['status'] == 'WARNING'
    assert any('force_igmp_version=1' in iss for iss in res_err['issues'])
    assert any('Aggressive IGMPv3' in iss for iss in res_err['issues'])
    assert any('igmp_qrv=0' in iss for iss in res_err['issues'])
    assert any('max memberships' in iss.lower() for iss in res_err['issues'])
    assert any('source filter' in iss.lower() for iss in res_err['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 296 tests passed successfully!"
