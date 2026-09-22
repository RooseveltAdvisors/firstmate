#!/usr/bin/env bash
# tests/fm-jev-icmp-guard.test.sh - Regression tests for Pattern 205 (ICMP Rate Limiting Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-icmp-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-icmp-guard.py"

echo "Running Pattern 205 regression tests..."

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
assert isinstance(s['in_msgs'], int)
assert isinstance(s['out_msgs'], int)
assert isinstance(s['in_errors'], int)
assert isinstance(s['ratelimit_global_drops'], int)
assert isinstance(s['ratelimit_host_drops'], int)
assert isinstance(s['icmp_ratelimit_ms'], int)
assert isinstance(s['issues'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-icmp-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    sys_dir = d / 'ipv4'
    sys_dir.mkdir()
    snmp_f = d / 'snmp'
    snmp6_f = d / 'snmp6'

    (sys_dir / 'icmp_ratelimit').write_text('1000\n')
    (sys_dir / 'icmp_ratemask').write_text('6168\n')
    (sys_dir / 'icmp_echo_ignore_broadcasts').write_text('1\n')
    (sys_dir / 'icmp_echo_ignore_all').write_text('0\n')

    # Mock clean snmp
    snmp_f.write_text(
        'Icmp: InMsgs InErrors InCsumErrors InDestUnreachs InTimeExcds InParmProbs InSrcQuenchs InRedirects InEchos InEchoReps InTimestamps InTimestampReps InAddrMasks InAddrMaskReps OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost OutDestUnreachs OutTimeExcds OutParmProbs OutSrcQuenchs OutRedirects OutEchos OutEchoReps OutTimestamps OutTimestampReps OutAddrMasks OutAddrMaskReps\n'
        'Icmp: 1000 2 0 100 0 0 0 0 500 500 0 0 0 0 1000 0 10 20 100 0 0 0 0 10 500 0 0 0 0\n'
    )
    snmp6_f.write_text(
        'Icmp6InMsgs\t100\n'
        'Icmp6InErrors\t0\n'
        'Icmp6InDestUnreachs\t10\n'
        'Icmp6InTimeExcds\t0\n'
        'Icmp6InParmProblems\t0\n'
        'Icmp6InEchos\t50\n'
        'Icmp6InEchoReplies\t50\n'
        'Icmp6OutMsgs\t100\n'
        'Icmp6OutErrors\t0\n'
        'Icmp6OutDestUnreachs\t10\n'
        'Icmp6OutTimeExcds\t0\n'
        'Icmp6OutParmProblems\t0\n'
        'Icmp6OutEchos\t10\n'
        'Icmp6OutEchoReplies\t50\n'
    )

    rep = mod.audit_icmp(proc_snmp=str(snmp_f), proc_snmp6=str(snmp6_f), proc_sys_ipv4=str(sys_dir))
    s = rep['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert s['in_msgs'] == 1100
    assert s['out_msgs'] == 1100
    assert s['in_errors'] == 2
    assert s['total_ratelimit_drops'] == 30

    # Mock broadcast ignore disabled -> WARNING
    (sys_dir / 'icmp_echo_ignore_broadcasts').write_text('0\n')
    rep2 = mod.audit_icmp(proc_snmp=str(snmp_f), proc_snmp6=str(snmp6_f), proc_sys_ipv4=str(sys_dir))
    assert rep2['summary']['status'] == 'WARNING'
    assert rep2['summary']['healthy'] is False

    # Mock high in_errors -> CRITICAL
    (sys_dir / 'icmp_echo_ignore_broadcasts').write_text('1\n')
    snmp_f.write_text(
        'Icmp: InMsgs InErrors InCsumErrors InDestUnreachs InTimeExcds InParmProbs InSrcQuenchs InRedirects InEchos InEchoReps InTimestamps InTimestampReps InAddrMasks InAddrMaskReps OutMsgs OutErrors OutRateLimitGlobal OutRateLimitHost OutDestUnreachs OutTimeExcds OutParmProbs OutSrcQuenchs OutRedirects OutEchos OutEchoReps OutTimestamps OutTimestampReps OutAddrMasks OutAddrMaskReps\n'
        'Icmp: 1000 100 0 100 0 0 0 0 500 500 0 0 0 0 1000 0 10 20 100 0 0 0 0 10 500 0 0 0 0\n'
    )
    rep3 = mod.audit_icmp(proc_snmp=str(snmp_f), proc_snmp6=str(snmp6_f), proc_sys_ipv4=str(sys_dir))
    assert rep3['summary']['status'] == 'CRITICAL'
    assert rep3['summary']['healthy'] is False
"
echo "ok - mocked unit tests pass"

echo "All Pattern 205 tests passed successfully."
