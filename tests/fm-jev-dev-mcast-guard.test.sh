#!/usr/bin/env bash
# tests/fm-jev-dev-mcast-guard.test.sh - Regression tests for Pattern 213 (Device Multicast & Promisc Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-dev-mcast-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-dev-mcast-guard.py"

echo "Running Pattern 213 regression tests..."

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
assert isinstance(s['total_interfaces'], int)
assert isinstance(s['total_filters'], int)
assert isinstance(s['promisc_count'], int)
assert isinstance(s['allmulti_count'], int)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
assert 'interfaces' in data
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
mod = import_module('fm-jev-dev-mcast-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sys_net = d / 'net'
    sys_net.mkdir()

    eth0 = sys_net / 'eth0'
    eth0.mkdir()
    (eth0 / 'flags').write_text('0x1003\n') # UP, BROADCAST, MULTICAST
    (eth0 / 'operstate').write_text('up\n')
    (eth0 / 'carrier').write_text('1\n')

    dev_mcast_f = d / 'dev_mcast'
    mcast_content = '''2    eth0          1     0     01005e000001
2    eth0          1     0     01005e0000fb
'''
    dev_mcast_f.write_text(mcast_content)

    # Scenario A: Nominal condition
    res = mod.audit_dev_mcast_guard(
        proc_dev_mcast=str(dev_mcast_f),
        sys_net_dir=str(sys_net),
    )
    assert res['summary']['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"summary\"][\"status\"]}'
    assert res['summary']['total_interfaces'] == 1
    assert res['summary']['total_filters'] == 2
    assert res['summary']['promisc_count'] == 0
    assert res['interfaces']['eth0']['filters'][0]['mac'] == '01:00:5e:00:00:01'

    # Scenario B: CRITICAL when unauthorized promiscuous mode is detected
    (eth0 / 'flags').write_text('0x1103\n') # IFF_PROMISC (0x100) added
    res_crit = mod.audit_dev_mcast_guard(
        proc_dev_mcast=str(dev_mcast_f),
        sys_net_dir=str(sys_net),
    )
    assert res_crit['summary']['status'] == 'CRITICAL', f'Expected CRITICAL, got {res_crit[\"summary\"][\"status\"]}'
    assert any('promiscuous mode' in issue for issue in res_crit['summary']['issues'])

    # Scenario C: WARNING when IFF_ALLMULTI is active
    (eth0 / 'flags').write_text('0x1203\n') # IFF_ALLMULTI (0x200) added
    res_warn = mod.audit_dev_mcast_guard(
        proc_dev_mcast=str(dev_mcast_f),
        sys_net_dir=str(sys_net),
    )
    assert res_warn['summary']['status'] == 'WARNING', f'Expected WARNING, got {res_warn[\"summary\"][\"status\"]}'
    assert any('ALLMULTI' in issue for issue in res_warn['summary']['issues'])
"
echo "ok - unit tests with mock procfs pass"

echo "All 6/6 tests passed successfully!"
