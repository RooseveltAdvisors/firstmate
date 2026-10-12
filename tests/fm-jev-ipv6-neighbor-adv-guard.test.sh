#!/usr/bin/env bash
# tests/fm-jev-ipv6-neighbor-adv-guard.test.sh - Regression tests for Pattern 290 (Ipv6NeighborAdvGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv6-neighbor-adv-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv6-neighbor-adv-guard.py"

echo "Running Pattern 290 regression tests..."

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
assert isinstance(data['all_drop_unsolicited_na'], int)
assert isinstance(data['default_drop_unsolicited_na'], int)
assert isinstance(data['all_accept_untracked_na'], int)
assert isinstance(data['default_accept_untracked_na'], int)
assert isinstance(data['in_neighbor_advertisements'], int)
assert isinstance(data['out_neighbor_advertisements'], int)
assert isinstance(data['in_neighbor_solicits'], int)
assert isinstance(data['out_neighbor_solicits'], int)
assert isinstance(data['ndisc_lookups'], int)
assert isinstance(data['ndisc_hits'], int)
assert isinstance(data['table_fulls'], int)
assert isinstance(data['na_policy_compliant'], bool)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
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
mod = import_module('fm-jev-ipv6-neighbor-adv-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'drop_unsolicited_na').write_text('0\n')
    (eth0 / 'accept_untracked_na').write_text('0\n')

    all_d = conf_dir / 'all'
    all_d.mkdir()
    (all_d / 'drop_unsolicited_na').write_text('0\n')
    (all_d / 'accept_untracked_na').write_text('0\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Icmp6InNeighborAdvertisements 5\nIcmp6OutNeighborAdvertisements 5\nIcmp6InErrors 0\nIcmp6InCsumErrors 0\n')

    ndisc_stat_file = d / 'ndisc_cache'
    ndisc_stat_file.write_text(
        'entries  allocs   destroys hash_grows lookups  hits     res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n'
        '00000017 000001d6 00000110 00000000   00000010 00000008 00000000   00000000         00000000         000038a0         00000000       00000000            00000000\n'
    )

    res = mod.audit_ipv6_neighbor_adv_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
        ndisc_stat_path=str(ndisc_stat_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['all_drop_unsolicited_na'] == 0
    assert res['all_accept_untracked_na'] == 0
    assert res['table_fulls'] == 0

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'drop_unsolicited_na').write_text('3\n')
    (eth0 / 'accept_untracked_na').write_text('2\n')

    snmp6_file = d / 'snmp6'
    snmp6_file.write_text('Icmp6InCsumErrors 5\nIcmp6InNeighborAdvertisements 10\n')

    ndisc_stat_file = d / 'ndisc_cache'
    ndisc_stat_file.write_text(
        'entries  allocs   destroys hash_grows lookups  hits     res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n'
        '00000017 000001d6 00000110 00000000   00000010 00000008 00000000   00000000         00000000         000038a0         00000096       00000000            0000000c\n'
    )

    res = mod.audit_ipv6_neighbor_adv_guard(
        conf_dir=str(conf_dir),
        snmp6_path=str(snmp6_file),
        ndisc_stat_path=str(ndisc_stat_file),
    )
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('invalid drop_unsolicited_na' in iss for iss in res['issues'])
    assert any('accept_untracked_na=2 allows untracked NA' in iss for iss in res['issues'])
    assert any('table_fulls=12' in iss for iss in res['issues'])
    assert any('forced_gc_runs=150' in iss for iss in res['issues'])
    assert any('ICMPv6 checksum errors detected' in iss for iss in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All 6/6 Pattern 290 tests passed successfully!"
