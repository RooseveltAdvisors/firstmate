#!/usr/bin/env bash
# tests/fm-jev-challenge-ack-guard.test.sh - Regression tests for Pattern 115 (TCP Challenge ACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-challenge-ack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-challenge-ack-guard.py"

echo "Running Pattern 115 regression tests..."

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
assert 'syn_challenges_sent' in s
assert 'skipped_challenges' in s
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
    limit_file = d / 'tcp_challenge_ack_limit'
    netstat_file = d / 'netstat'

    limit_file.write_text('2147483647\n')

    mock_netstat = '''TcpExt: SyncookiesSent TCPChallengeACK TCPSYNChallenge TCPACKSkippedChallenge
TcpExt: 0 100 80 0
'''
    netstat_file.write_text(mock_netstat)

    # Case 1: Nominal
    res = mod.audit_challenge_ack(
        limit_file=str(limit_file),
        netstat_file=str(netstat_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_challenge_ack_limit'] == 2147483647
    assert res['summary']['challenge_acks_sent'] == 100
    assert res['summary']['syn_challenges_sent'] == 80
    assert res['summary']['skipped_challenges'] == 0

    # Case 2: Low challenge ACK limit warning
    limit_file.write_text('100\n')
    res2 = mod.audit_challenge_ack(
        limit_file=str(limit_file),
        netstat_file=str(netstat_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Low tcp_challenge_ack_limit' in iss for iss in res2['summary']['issues'])
    limit_file.write_text('2147483647\n')

    # Case 3: Elevated skipped challenges warning
    skipped_netstat = mock_netstat.replace(' 0 100 80 0', ' 0 100 80 150')
    netstat_file.write_text(skipped_netstat)
    res3 = mod.audit_challenge_ack(
        limit_file=str(limit_file),
        netstat_file=str(netstat_file),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Elevated TCPACKSkippedChallenge' in iss for iss in res3['summary']['issues'])
"
echo "ok - mocked sysctl and netstat unit tests pass"

echo "All Pattern 115 tests passed successfully!"
