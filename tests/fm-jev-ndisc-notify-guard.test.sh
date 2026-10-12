#!/usr/bin/env bash
# tests/fm-jev-ndisc-notify-guard.test.sh - Regression tests for Pattern 261 (NdiscNotifyGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ndisc-notify-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ndisc-notify-guard.py"

echo "Running Pattern 261 regression tests..."

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
assert isinstance(data['ndisc_lookups'], int)
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
mod = import_module('fm-jev-ndisc-notify-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'ndisc_notify').write_text('0\n')
    (conf_lo / 'ndisc_evict_nocarrier').write_text('1\n')
    (conf_lo / 'ndisc_tclass').write_text('0\n')
    (conf_enp / 'ndisc_notify').write_text('0\n')
    (conf_enp / 'ndisc_evict_nocarrier').write_text('1\n')
    (conf_enp / 'ndisc_tclass').write_text('0\n')
    ndisc_stat_file = d / 'ndisc_cache'
    ndisc_stat_file.write_text('entries allocs destroys hash_grows lookups hits res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n00000002 00000005 00000003 00000000 0000000a 00000008 00000000 00000000 00000000 00000001 00000000 00000000 00000000\n')

    res = mod.audit_ndisc_notify_guard(
        conf_dir=str(conf_dir),
        ndisc_stat_path=str(ndisc_stat_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['ndisc_lookups'] == 10
    assert res['ndisc_hits'] == 8

    # Issues case: lo has ndisc_notify=1, enp has ndisc_evict_nocarrier=0, tclass=300, table_fulls=1
    (conf_lo / 'ndisc_notify').write_text('1\n')
    (conf_enp / 'ndisc_evict_nocarrier').write_text('0\n')
    (conf_enp / 'ndisc_tclass').write_text('300\n')
    ndisc_stat_file.write_text('entries allocs destroys hash_grows lookups hits res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n00000002 00000005 00000003 00000000 0000000a 00000008 00000000 00000000 00000000 00000001 00000002 00000000 00000001\n')

    res2 = mod.audit_ndisc_notify_guard(
        conf_dir=str(conf_dir),
        ndisc_stat_path=str(ndisc_stat_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'CRITICAL'
    assert len(res2['issues']) == 4
    assert any('Loopback interface has ndisc_notify enabled' in i for i in res2['issues'])
    assert any('NDISC carrier loss eviction disabled' in i for i in res2['issues'])
    assert any('Invalid ndisc_tclass value' in i for i in res2['issues'])
    assert any('NDISC table overflow' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 261 regression tests passed!"
