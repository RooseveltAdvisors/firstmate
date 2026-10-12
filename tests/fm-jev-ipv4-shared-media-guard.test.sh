#!/usr/bin/env bash
# tests/fm-jev-ipv4-shared-media-guard.test.sh - Regression tests for Pattern 297 (Ipv4SharedMediaGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ipv4-shared-media-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ipv4-shared-media-guard.py"

echo "Running Pattern 297 regression tests..."

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
assert data['pattern'] == 297
assert data['name'] == 'ipv4_shared_media'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['interfaces_audited'], int)
assert isinstance(data['all_secure_redirects'], int)
assert isinstance(data['default_secure_redirects'], int)
assert isinstance(data['all_shared_media'], int)
assert isinstance(data['default_shared_media'], int)
assert isinstance(data['all_bootp_relay'], int)
assert isinstance(data['default_bootp_relay'], int)
assert isinstance(data['all_proxy_arp_pvlan'], int)
assert isinstance(data['default_proxy_arp_pvlan'], int)
assert isinstance(data['in_redirects'], int)
assert isinstance(data['out_redirects'], int)
assert isinstance(data['in_discards'], int)
assert isinstance(data['out_discards'], int)
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
mod = import_module('fm-jev-ipv4-shared-media-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    conf = d / 'conf'
    conf.mkdir()

    for iface in ('all', 'default', 'eth0'):
        idir = conf / iface
        idir.mkdir()
        (idir / 'shared_media').write_text('1\n')
        (idir / 'secure_redirects').write_text('1\n')
        (idir / 'bootp_relay').write_text('0\n')
        (idir / 'proxy_arp_pvlan').write_text('0\n')

    snmp = d / 'snmp'
    snmp.write_text(
        'Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes\n'
        'Ip: 1 64 1000 0 0 0 0 5 995 800 10 2\n'
        'Icmp: InMsgs InErrors InCsumErrors InDestUnreachs InTimeExcds InParmProbs InSrcQuenchs InRedirects InEchos InEchoReps OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost OutDestUnreachs OutTimeExcds OutParmProbs OutSrcQuenchs OutRedirects\n'
        'Icmp: 100 0 0 10 0 0 0 0 50 40 100 0 0 0 10 0 0 0 0\n'
    )

    res = mod.evaluate_ipv4_shared_media(
        conf_dir=str(conf),
        snmp_path=str(snmp),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['interfaces_audited'] == 3
    assert res['all_secure_redirects'] == 1
    assert res['all_shared_media'] == 1
    assert res['all_bootp_relay'] == 0
    assert res['in_redirects'] == 0
    assert res['out_redirects'] == 0
    assert res['in_discards'] == 5
    assert len(res['issues']) == 0

    # Test error cases: disabled secure_redirects, enabled bootp_relay, invalid values
    (conf / 'eth0' / 'secure_redirects').write_text('0\n')
    (conf / 'eth0' / 'bootp_relay').write_text('1\n')
    (conf / 'eth0' / 'shared_media').write_text('5\n')

    res_err = mod.evaluate_ipv4_shared_media(
        conf_dir=str(conf),
        snmp_path=str(snmp),
    )
    assert res_err['healthy'] is False
    assert res_err['status'] == 'WARNING'
    assert any('secure_redirects=0' in iss for iss in res_err['issues'])
    assert any('bootp_relay=1' in iss for iss in res_err['issues'])
    assert any('Invalid shared_media' in iss for iss in res_err['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 297 tests passed successfully!"
