#!/usr/bin/env bash
# tests/fm-jev-ipv4-martian-guard.test.sh - Regression tests for Pattern 292 (Ipv4MartianGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv4-martian-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv4-martian-guard.py"

echo "Running Pattern 292 regression tests..."

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
assert data['pattern'] == 292
assert data['name'] == 'ipv4_martian'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['all_log_martians'], int)
assert isinstance(data['default_log_martians'], int)
assert isinstance(data['all_src_valid_mark'], int)
assert isinstance(data['default_src_valid_mark'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['in_no_routes'], int)
assert isinstance(data['in_addr_errors'], int)
assert isinstance(data['in_unknown_protos'], int)
assert isinstance(data['rp_filter_drops'], int)
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
mod = import_module('fm-jev-ipv4-martian-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'log_martians').write_text('0\n')
    (eth0 / 'src_valid_mark').write_text('0\n')
    (eth0 / 'disable_policy').write_text('0\n')
    (eth0 / 'disable_xfrm').write_text('0\n')

    all_d = conf_dir / 'all'
    all_d.mkdir()
    (all_d / 'log_martians').write_text('0\n')
    (all_d / 'src_valid_mark').write_text('0\n')
    (all_d / 'disable_policy').write_text('0\n')
    (all_d / 'disable_xfrm').write_text('0\n')

    snmp_file = d / 'snmp'
    snmp_file.write_text('Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates\nIp: 2 64 100 0 0 0 0 0 100 100 0 0 0 0 0 0 0 0 0\n')

    netstat_file = d / 'netstat'
    netstat_file.write_text('TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed IPReversePathFilter\nTcpExt: 0 0 0 0\n')

    res = mod.evaluate_ipv4_martian_policy(
        conf_dir=str(conf_dir),
        snmp_path=str(snmp_file),
        netstat_path=str(netstat_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['interfaces_audited'] == 2
    assert res['all_log_martians'] == 0
    assert res['all_src_valid_mark'] == 0

# Test degraded case with invalid IPsec bypass on physical interface
with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf_dir = d / 'conf'
    conf_dir.mkdir()
    eth0 = conf_dir / 'eth0'
    eth0.mkdir()
    (eth0 / 'log_martians').write_text('0\n')
    (eth0 / 'src_valid_mark').write_text('0\n')
    (eth0 / 'disable_policy').write_text('1\n')
    (eth0 / 'disable_xfrm').write_text('0\n')

    snmp_file = d / 'snmp'
    snmp_file.write_text('')
    netstat_file = d / 'netstat'
    netstat_file.write_text('')

    res = mod.evaluate_ipv4_martian_policy(
        conf_dir=str(conf_dir),
        snmp_path=str(snmp_file),
        netstat_path=str(netstat_file),
    )
    assert res['healthy'] is False
    assert res['status'] == 'DEGRADED'
    assert any('disable_policy=1' in i for i in res['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 292 regression tests passed successfully."
