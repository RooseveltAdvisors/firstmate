#!/usr/bin/env bash
# tests/fm-jev-proxy-ndp-guard.test.sh - Regression tests for Pattern 259 (ProxyNdpGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-proxy-ndp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-proxy-ndp-guard.py"

echo "Running Pattern 259 regression tests..."

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
assert isinstance(data['enabled_interfaces_count'], int)
assert isinstance(data['ndisc_lookups'], int)
assert isinstance(data['ndisc_hits'], int)
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
mod = import_module('fm-jev-proxy-ndp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_lo = conf_dir / 'lo'
    conf_enp = conf_dir / 'enp'
    conf_lo.mkdir(parents=True)
    conf_enp.mkdir(parents=True)
    (conf_lo / 'proxy_ndp').write_text('0\n')
    (conf_enp / 'proxy_ndp').write_text('0\n')
    ndisc_file = d / 'ndisc_cache'
    ndisc_file.write_text(
        'entries allocs destroys hash_grows lookups hits res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n'
        '00000017 000001d1 00000110 00000000 0000000a 00000008 00000000 00000000 00000000 00003872 00000000 00000000 00000000\n'
    )

    res = mod.audit_proxy_ndp_guard(
        proxy_glob=str(conf_dir / '*' / 'proxy_ndp'),
        ndisc_stat_path=str(ndisc_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['enabled_interfaces_count'] == 0
    assert res['lo_proxy_ndp'] == 0
    assert res['ndisc_lookups'] == 10
    assert res['ndisc_hits'] == 8

    # Issues case: enabled on lo and all, forced_gc and table_full
    conf_all = conf_dir / 'all'
    conf_all.mkdir(parents=True)
    (conf_lo / 'proxy_ndp').write_text('1\n')
    (conf_all / 'proxy_ndp').write_text('1\n')
    ndisc_file.write_text(
        'entries allocs destroys hash_grows lookups hits res_failed rcv_probes_mcast rcv_probes_ucast periodic_gc_runs forced_gc_runs unresolved_discards table_fulls\n'
        '00000017 000001d1 00000110 00000000 0000000a 00000008 00000000 00000000 00000000 00003872 00000005 00000080 00000002\n'
    )

    res2 = mod.audit_proxy_ndp_guard(
        proxy_glob=str(conf_dir / '*' / 'proxy_ndp'),
        ndisc_stat_path=str(ndisc_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'CRITICAL'
    assert len(res2['issues']) == 4
    assert any('Loopback interface has Proxy NDP enabled' in i for i in res2['issues'])
    assert any('Global or default Proxy NDP enabled' in i for i in res2['issues'])
    assert any('NDISC neighbor table overflow detected' in i for i in res2['issues'])
    assert any('Elevated NDISC unresolved discards' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 259 regression tests passed!"
