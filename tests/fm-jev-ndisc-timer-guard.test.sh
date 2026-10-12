#!/usr/bin/env bash
# tests/fm-jev-ndisc-timer-guard.test.sh - Regression tests for Pattern 268 (NdiscTimerGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ndisc-timer-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ndisc-timer-guard.py"

echo "Running Pattern 268 regression tests..."

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
assert isinstance(data['base_reachable_time_ms'], int)
assert isinstance(data['delay_first_probe_time'], int)
assert isinstance(data['retrans_time_ms'], int)
assert isinstance(data['issues'], list)
assert isinstance(data['current_entries'], int)
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
mod = import_module('fm-jev-ndisc-timer-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    neigh_dir = d / 'neigh'
    neigh_dir.mkdir(parents=True)
    (neigh_dir / 'base_reachable_time_ms').write_text('30000\n')
    (neigh_dir / 'delay_first_probe_time').write_text('5\n')
    (neigh_dir / 'retrans_time_ms').write_text('1000\n')
    (neigh_dir / 'gc_stale_time').write_text('60\n')
    (neigh_dir / 'mcast_solicit').write_text('3\n')
    (neigh_dir / 'ucast_solicit').write_text('3\n')
    (neigh_dir / 'unres_qlen').write_text('101\n')
    (neigh_dir / 'unres_qlen_bytes').write_text('212992\n')

    stat_file = d / 'ndisc_cache'
    stat_file.write_text(
        'entries  allocs   destroys hash_grows lookups  hits     res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n'
        '00000005 00000010 0000000b 00000000   00000000 00000000 00000000   00000000         00000000         00000010         00000000       00000000            00000000\n'
    )

    res = mod.audit_ndisc_timer_guard(
        neigh_dir=str(neigh_dir),
        stat_path=str(stat_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['base_reachable_time_ms'] == 30000
    assert res['delay_first_probe_time'] == 5
    assert res['retrans_time_ms'] == 1000

    # Issues case: base_reachable_ms < 1000, delay < 1, retrans < 100, mcast=0, ucast=0, unres=0, table_fulls=1
    (neigh_dir / 'base_reachable_time_ms').write_text('500\n')
    (neigh_dir / 'delay_first_probe_time').write_text('0\n')
    (neigh_dir / 'retrans_time_ms').write_text('50\n')
    (neigh_dir / 'mcast_solicit').write_text('0\n')
    (neigh_dir / 'ucast_solicit').write_text('0\n')
    (neigh_dir / 'unres_qlen').write_text('0\n')

    stat_file.write_text(
        'entries  allocs   destroys hash_grows lookups  hits     res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n'
        '00000010 00000020 00000010 00000000   00000030 00000020 00000002   00000001         00000001         00000005         00000003       00000004            00000001\n'
    )

    res2 = mod.audit_ndisc_timer_guard(
        neigh_dir=str(neigh_dir),
        stat_path=str(stat_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'CRITICAL'
    assert len(res2['issues']) == 9
    assert any('base_reachable_time_ms=500 outside safe bounds' in i for i in res2['issues'])
    assert any('table full errors detected: 1' in i for i in res2['issues'])
    assert any('Forced neighbor GC runs under memory pressure detected: 3' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 268 regression tests passed!"
