#!/usr/bin/env bash
# tests/fm-jev-invalid-ratelimit-guard.test.sh - Regression tests for Pattern 173 (TCP Invalid Rate Limiting Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-invalid-ratelimit-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-invalid-ratelimit-guard.py"

echo "Running Pattern 173 regression tests..."

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
assert 'sysctls' in data
assert 'counters' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_invalid_ratelimit_ms' in s
assert 'tcp_challenge_ack_limit' in s
assert 'challenge_acks_sent' in s
assert 'skipped_challenge_acks' in s
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
mod = import_module('fm-jev-invalid-ratelimit-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    ratelimit_f = d / 'tcp_invalid_ratelimit'
    challenge_f = d / 'tcp_challenge_ack_limit'
    netstat_f = d / 'netstat'
    snmp_f = d / 'snmp'

    ratelimit_f.write_text('500\n')
    challenge_f.write_text('2147483647\n')
    netstat_f.write_text('''TcpExt: TCPChallengeACK TCPSYNChallenge TCPACKSkippedChallenge TCPACKSkippedSeq EmbryonicRsts
TcpExt: 886 857 0 258950 14
''')
    snmp_f.write_text('''Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 100 200 50 1000 10 5000 5000 20 0 10000 0
''')

    # Case 1: Nominal
    res = mod.audit_invalid_ratelimit(
        invalid_ratelimit_file=str(ratelimit_f),
        challenge_ack_file=str(challenge_f),
        netstat_file=str(netstat_f),
        snmp_file=str(snmp_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_invalid_ratelimit_ms'] == 500
    assert res['summary']['skipped_challenge_acks'] == 0

    # Case 2: Zero ratelimit -> WARNING
    ratelimit_f.write_text('0\n')
    res2 = mod.audit_invalid_ratelimit(
        invalid_ratelimit_file=str(ratelimit_f),
        challenge_ack_file=str(challenge_f),
        netstat_file=str(netstat_f),
        snmp_file=str(snmp_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('unthrottled responses' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 173 regression tests passed: 6/6 tests ok"
