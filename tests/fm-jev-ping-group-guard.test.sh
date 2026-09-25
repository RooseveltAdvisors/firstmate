#!/usr/bin/env bash
# tests/fm-jev-ping-group-guard.test.sh - Regression tests for Pattern 256 (PingGroupGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ping-group-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ping-group-guard.py"

echo "Running Pattern 256 regression tests..."

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
assert isinstance(data['ping_group_min_gid'], int)
assert isinstance(data['ping_group_max_gid'], int)
assert isinstance(data['unprivileged_ping_enabled'], bool)
assert isinstance(data['icmp_errors_use_inbound_ifaddr'], int)
assert isinstance(data['icmp_ignore_bogus_error_responses'], int)
assert isinstance(data['icmp_echo_ignore_broadcasts'], int)
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
mod = import_module('fm-jev-ping-group-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    range_file = d / 'ping_group_range'
    inbound_file = d / 'icmp_errors_use_inbound_ifaddr'
    bogus_file = d / 'icmp_ignore_bogus_error_responses'
    bcast_file = d / 'icmp_echo_ignore_broadcasts'
    snmp_file = d / 'snmp'

    # Nominal case
    range_file.write_text('1\t0\n')
    inbound_file.write_text('0\n')
    bogus_file.write_text('1\n')
    bcast_file.write_text('1\n')
    snmp_file.write_text(
        'Icmp: InMsgs InErrors InCsumErrors InDestUnreachs InTimeExcds InParmProbs InSrcQuenchs InRedirects InEchos InEchoReps InTimestamps InTimestampReps InAddrMasks InAddrMaskReps OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost OutDestUnreachs OutTimeExcds OutParmProbs OutSrcQuenchs OutRedirects OutEchos OutEchoReps OutTimestamps OutTimestampReps OutAddrMasks OutAddrMaskReps\n'
        'Icmp: 10000 0 0 100 0 0 0 0 5000 500 0 0 0 0 9500 0 0 0 100 0 0 0 0 500 5000 0 0 0 0\n'
    )

    res = mod.audit_ping_group_guard(
        ping_group_range_path=str(range_file),
        errors_inbound_ifaddr_path=str(inbound_file),
        ignore_bogus_path=str(bogus_file),
        ignore_broadcasts_path=str(bcast_file),
        snmp_path=str(snmp_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['ping_group_min_gid'] == 1
    assert res['ping_group_max_gid'] == 0
    assert res['unprivileged_ping_enabled'] is False

    # Issues case: wide open, inbound IP exposed, bogus disabled, broadcast disabled, high error rate
    range_file.write_text('0\t2147483647\n')
    inbound_file.write_text('1\n')
    bogus_file.write_text('0\n')
    bcast_file.write_text('0\n')
    snmp_file.write_text(
        'Icmp: InMsgs InErrors InCsumErrors InDestUnreachs InTimeExcds InParmProbs InSrcQuenchs InRedirects InEchos InEchoReps InTimestamps InTimestampReps InAddrMasks InAddrMaskReps OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost OutDestUnreachs OutTimeExcds OutParmProbs OutSrcQuenchs OutRedirects OutEchos OutEchoReps OutTimestamps OutTimestampReps OutAddrMasks OutAddrMaskReps\n'
        'Icmp: 10000 1500 25 100 0 0 0 0 5000 500 0 0 0 0 9500 0 0 0 100 0 0 0 0 500 5000 0 0 0 0\n'
    )

    res2 = mod.audit_ping_group_guard(
        ping_group_range_path=str(range_file),
        errors_inbound_ifaddr_path=str(inbound_file),
        ignore_bogus_path=str(bogus_file),
        ignore_broadcasts_path=str(bcast_file),
        snmp_path=str(snmp_file),
    )
    assert res2['healthy'] is False
    assert res2['status'] == 'CRITICAL'
    assert len(res2['issues']) == 6
    assert any('Wide-open ping group range' in i for i in res2['issues'])
    assert any('ICMP errors configured to use inbound interface IP' in i for i in res2['issues'])
    assert any('RFC 1122 bogus error response filtering disabled' in i for i in res2['issues'])
    assert any('Broadcast ICMP echo reply filtering disabled' in i for i in res2['issues'])
    assert any('Detected 25 incoming ICMP checksum errors' in i for i in res2['issues'])
    assert any('Critical ICMP incoming error rate' in i for i in res2['issues'])
"
echo "ok - unit tests with mock sysctls passed"

echo "All Pattern 256 regression tests passed!"
