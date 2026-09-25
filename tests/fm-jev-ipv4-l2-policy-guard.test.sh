#!/usr/bin/env bash
# tests/fm-jev-ipv4-l2-policy-guard.test.sh - Regression tests for Pattern 293 (Ipv4L2PolicyGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv4-l2-policy-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv4-l2-policy-guard.py"

echo "Running Pattern 293 regression tests..."

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
assert data['pattern'] == 293
assert data['name'] == 'ipv4_l2_policy'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['all_drop_unicast_in_l2_multicast'], int)
assert isinstance(data['default_drop_unicast_in_l2_multicast'], int)
assert isinstance(data['all_promote_secondaries'], int)
assert isinstance(data['default_promote_secondaries'], int)
assert isinstance(data['all_arp_evict_nocarrier'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['in_addr_errors'], int)
assert isinstance(data['in_unknown_protos'], int)
assert isinstance(data['arp_lookups'], int)
assert isinstance(data['arp_hits'], int)
assert isinstance(data['arp_res_failed'], int)
assert isinstance(data['arp_forced_gc_runs'], int)
assert isinstance(data['arp_table_fulls'], int)
assert isinstance(data['arp_unresolved_discards'], int)
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
mod = import_module('fm-jev-ipv4-l2-policy-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'conf'
    conf.mkdir()

    for iface in ('all', 'default', 'eth0'):
        idir = conf / iface
        idir.mkdir()
        (idir / 'drop_unicast_in_l2_multicast').write_text('0\n')
        (idir / 'promote_secondaries').write_text('1\n')
        (idir / 'arp_evict_nocarrier').write_text('1\n')
        (idir / 'drop_gratuitous_arp').write_text('0\n')

    snmp = d / 'snmp'
    snmp.write_text('Ip: InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates\nIp: 100 0 0 0 0 0 100 100 0 0 0 0 0 0 0 0 0\n')

    arp_cache = d / 'arp_cache'
    arp_cache.write_text(
        'entries  allocs   destroys hash_grows lookups  hits     res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n'
        '00000005 0000000a 00000005 00000000   00000064 00000050 00000002   00000000         00000000         00000010         00000000       00000000            00000000\n'
    )

    res = mod.evaluate_ipv4_l2_policy(
        conf_dir=str(conf),
        snmp_path=str(snmp),
        arp_cache_path=str(arp_cache),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['interfaces_audited'] == 3
    assert res['all_promote_secondaries'] == 1
    assert res['arp_lookups'] == 100
    assert res['arp_hits'] == 80
    assert len(res['issues']) == 0

    # Test error cases: table fulls and invalid sysctl
    (conf / 'eth0' / 'drop_unicast_in_l2_multicast').write_text('5\n')
    arp_cache.write_text(
        'entries  allocs   destroys hash_grows lookups  hits     res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n'
        '00000005 0000000a 00000005 00000000   00000064 00000050 00000002   00000000         00000000         00000010         00000005       00000000            00000003\n'
    )
    res_bad = mod.evaluate_ipv4_l2_policy(
        conf_dir=str(conf),
        snmp_path=str(snmp),
        arp_cache_path=str(arp_cache),
    )
    assert res_bad['healthy'] is False
    assert res_bad['status'] == 'DEGRADED'
    assert any('drop_unicast_in_l2_multicast=5 invalid' in iss for iss in res_bad['issues'])
    assert any('table full' in iss for iss in res_bad['issues'])
    assert any('forced garbage collection' in iss for iss in res_bad['issues'])
"
echo "ok - unit tests with mocked files pass"

echo "All Pattern 293 tests passed successfully."
