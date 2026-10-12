#!/usr/bin/env bash
# tests/fm-jev-challenge-ack-guard.test.sh - Regression tests for Pattern 134 (TCP Challenge ACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-challenge-ack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-challenge-ack-guard.py"

echo "Running Pattern 134 regression tests..."

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
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_challenge_ack_limit' in s
assert 'challenge_acks_sent' in s
assert 'challenges_skipped' in s
assert 'skip_ratio_pct' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and /proc/net/netstat files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-challenge-ack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    limit_f = d / 'tcp_challenge_ack_limit'
    netstat_f = d / 'netstat'

    limit_f.write_text('1000\n')
    netstat_f.write_text('''TcpExt: TCPChallengeACK TCPSYNChallenge TCPACKSkippedChallenge TCPDelivered
TcpExt: 500 450 0 1000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_challenge_ack(
        challenge_ack_limit_file=str(limit_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_challenge_ack_limit'] == 1000
    assert res['summary']['challenge_acks_sent'] == 500
    assert res['summary']['syn_challenges_sent'] == 450
    assert res['summary']['challenges_skipped'] == 0
    assert res['summary']['skip_ratio_pct'] == 0.0

    # Case 2: Overly restrictive rate limit (< 100/s) -> WARNING
    limit_f.write_text('50\n')
    res2 = mod.audit_challenge_ack(
        challenge_ack_limit_file=str(limit_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('overly restrictive' in iss for iss in res2['summary']['issues'])
    limit_f.write_text('1000\n')

    # Case 3: Completely disabled (limit == 0) -> CRITICAL
    limit_f.write_text('0\n')
    res3 = mod.audit_challenge_ack(
        challenge_ack_limit_file=str(limit_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'CRITICAL'
    assert any('completely disabled' in iss for iss in res3['summary']['issues'])
    limit_f.write_text('1000\n')

    # Case 4: High skipped challenge ACKs (> 10% and > 100 dropped) -> WARNING
    netstat_f.write_text('''TcpExt: TCPChallengeACK TCPSYNChallenge TCPACKSkippedChallenge TCPDelivered
TcpExt: 500 450 150 1000000
''')
    res4 = mod.audit_challenge_ack(
        challenge_ack_limit_file=str(limit_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('Elevated Challenge ACK drops' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 134 regression tests passed!"
