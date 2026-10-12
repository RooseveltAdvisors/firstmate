#!/usr/bin/env bash
# tests/fm-jev-tcp-ack-skipped-guard.test.sh - Regression tests for Pattern 223 (TCP Duplicate ACK Throttling & Skipped ACK Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tcp-ack-skipped-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tcp-ack-skipped-guard.py"

echo "Running Pattern 223 regression tests..."

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
assert 'summary' in data
s = data['summary']
assert 'total_skipped_acks' in s
assert 'skipped_seq' in s
assert 'skipped_paws' in s
assert 'skipped_syn_recv' in s
assert 'skipped_challenge' in s
assert 'invalid_ratelimit_ms' in s
assert isinstance(s['total_skipped_acks'], int)
assert isinstance(s['invalid_ratelimit_ms'], int)
assert isinstance(data['reasons'], list)
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked procfs files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-tcp-ack-skipped-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    netstat_f = d / 'netstat'
    ratelimit_f = d / 'tcp_invalid_ratelimit'

    # Scenario A: Nominal condition
    ratelimit_f.write_text('500\n')
    netstat_content = '''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed TCPACKSkippedSynRecv TCPACKSkippedPAWS TCPACKSkippedSeq TCPACKSkippedFinWait2 TCPACKSkippedTimeWait TCPACKSkippedChallenge TCPWinProbe TCPChallengeACK
TcpExt: 0 0 0 10 20 100 0 5 0 50 15
'''
    netstat_f.write_text(netstat_content)

    res = mod.audit_tcp_ack_skipped(
        netstat_path=str(netstat_f),
        ratelimit_path=str(ratelimit_f),
        warn_challenge_acks=1000,
        crit_challenge_acks=10000,
    )
    assert res['status'] == 'HEALTHY', f'Expected HEALTHY, got {res[\"status\"]}'
    assert res['summary']['total_skipped_acks'] == 135
    assert res['summary']['skipped_seq'] == 100
    assert res['summary']['skipped_paws'] == 20
    assert res['summary']['skipped_challenge'] == 0
    assert res['summary']['invalid_ratelimit_ms'] == 500

    # Scenario B: WARNING on disabled rate limit (0)
    ratelimit_f.write_text('0\n')
    res_warn = mod.audit_tcp_ack_skipped(
        netstat_path=str(netstat_f),
        ratelimit_path=str(ratelimit_f),
    )
    assert res_warn['status'] == 'WARNING', f'Expected WARNING, got {res_warn[\"status\"]}'
    assert any('tcp_invalid_ratelimit is 0' in r for r in res_warn['reasons'])

    # Scenario C: CRITICAL on high challenge acks
    ratelimit_f.write_text('500\n')
    netstat_crit = '''TcpExt: SyncookiesSent SyncookiesRecv SyncookiesFailed TCPACKSkippedSynRecv TCPACKSkippedPAWS TCPACKSkippedSeq TCPACKSkippedFinWait2 TCPACKSkippedTimeWait TCPACKSkippedChallenge TCPWinProbe TCPChallengeACK
TcpExt: 0 0 0 10 20 100 0 5 15000 50 15
'''
    netstat_f.write_text(netstat_crit)
    res_crit = mod.audit_tcp_ack_skipped(
        netstat_path=str(netstat_f),
        ratelimit_path=str(ratelimit_f),
        warn_challenge_acks=1000,
        crit_challenge_acks=10000,
    )
    assert res_crit['status'] == 'CRITICAL', f'Expected CRITICAL, got {res_crit[\"status\"]}'
    assert any('Critically high suppressed challenge ACKs' in r for r in res_crit['reasons'])
"
echo "ok - unit tests with mock procfs pass"

echo "All 6/6 tests passed successfully!"
