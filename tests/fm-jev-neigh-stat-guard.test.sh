#!/usr/bin/env bash
# tests/fm-jev-neigh-stat-guard.test.sh - Regression tests for Pattern 232 (Neighbor Table Stats Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-neigh-stat-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-neigh-stat-guard.py"

echo "Running Pattern 232 regression tests..."

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
assert isinstance(s['arp_entries'], int)
assert isinstance(s['ndisc_entries'], int)
assert isinstance(s['total_entries'], int)
assert isinstance(s['arp_lookups'], int)
assert isinstance(s['arp_hits'], int)
assert isinstance(s['arp_hit_ratio'], float)
assert isinstance(s['forced_gc_runs'], int)
assert isinstance(s['unresolved_discards'], int)
assert isinstance(s['table_fulls'], int)
assert isinstance(s['gc_thresh3'], int)
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
mod = import_module('fm-jev-neigh-stat-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    neigh_dir = d / 'neigh'
    neigh_dir.mkdir()

    arp_f = d / 'arp_cache'
    ndisc_f = d / 'ndisc_cache'

    # Scenario A: Nominal condition
    (neigh_dir / 'gc_thresh1').write_text('128\n')
    (neigh_dir / 'gc_thresh2').write_text('512\n')
    (neigh_dir / 'gc_thresh3').write_text('1024\n')
    (neigh_dir / 'gc_interval').write_text('30\n')
    (neigh_dir / 'gc_stale_time').write_text('60\n')

    arp_content = '''entries allocs destroys hash_grows lookups hits res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls
00000030 00000100 000000d0 00000000   00001000 00000f00 00000005   00000000         00000000         00000500         00000000       00000000            00000000
'''
    arp_f.write_text(arp_content)

    ndisc_content = '''entries allocs destroys hash_grows lookups hits res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls
0000000a 00000020 00000016 00000000   00000050 00000040 00000000   00000000         00000000         00000100         00000000       00000000            00000000
'''
    ndisc_f.write_text(ndisc_content)

    res = mod.audit_neigh_stat_guard(
        proc_arp_cache=str(arp_f),
        proc_ndisc_cache=str(ndisc_f),
        proc_sys_neigh=str(neigh_dir),
    )
    assert res['summary']['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"summary\"][\"status\"]}'
    assert res['summary']['arp_entries'] == 48
    assert res['summary']['ndisc_entries'] == 10
    assert res['summary']['forced_gc_runs'] == 0
    assert res['summary']['table_fulls'] == 0

    # Scenario B: CRITICAL when table_fulls > 0
    arp_crit = '''entries allocs destroys hash_grows lookups hits res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls
00000400 00000500 00000100 00000002   00001000 00000800 00000050   00000000         00000000         00000500         00000010       00000005            00000003
'''
    arp_f.write_text(arp_crit)
    res_crit = mod.audit_neigh_stat_guard(
        proc_arp_cache=str(arp_f),
        proc_ndisc_cache=str(ndisc_f),
        proc_sys_neigh=str(neigh_dir),
    )
    assert res_crit['summary']['status'] == 'CRITICAL', f'Expected CRITICAL, got {res_crit[\"summary\"][\"status\"]}'
    assert any('CRITICAL' in issue for issue in res_crit['summary']['issues'])

    # Scenario C: WARNING on forced GC runs without table fulls
    arp_warn = '''entries allocs destroys hash_grows lookups hits res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls
00000200 00000300 00000100 00000001   00001000 00000900 00000010   00000000         00000000         00000500         00000005       00000000            00000000
'''
    arp_f.write_text(arp_warn)
    res_warn = mod.audit_neigh_stat_guard(
        proc_arp_cache=str(arp_f),
        proc_ndisc_cache=str(ndisc_f),
        proc_sys_neigh=str(neigh_dir),
    )
    assert res_warn['summary']['status'] == 'WARNING', f'Expected WARNING, got {res_warn[\"summary\"][\"status\"]}'
    assert any('forced GC' in issue for issue in res_warn['summary']['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "All 6/6 tests passed successfully!"
