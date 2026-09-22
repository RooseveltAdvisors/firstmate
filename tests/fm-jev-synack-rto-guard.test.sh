#!/usr/bin/env bash
# tests/fm-jev-synack-rto-guard.test.sh - Regression tests for Pattern 143 (TCP SYN/ACK RTO Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-synack-rto-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-synack-rto-guard.py"

echo "Running Pattern 143 regression tests..."

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
assert 'tcp_synack_retries' in s
assert 'tcp_syn_retries' in s
assert 'synack_timeout_seconds' in s
assert 'syn_retrans' in s
assert 'syn_retrans_ratio_pct' in s
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
mod = import_module('fm-jev-synack-rto-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    synack_f = d / 'tcp_synack_retries'
    syn_f = d / 'tcp_syn_retries'
    linear_f = d / 'tcp_syn_linear_timeouts'
    netstat_f = d / 'netstat'

    synack_f.write_text('5\n')
    syn_f.write_text('6\n')
    linear_f.write_text('4\n')
    netstat_f.write_text('''TcpExt: TCPSynRetrans TCPTimeouts TCPSpuriousRTOs TCPDelivered
TcpExt: 1000 5000 10 10000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_synack_rto_guard(
        synack_retries_file=str(synack_f),
        syn_retries_file=str(syn_f),
        linear_timeouts_file=str(linear_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_synack_retries'] == 5
    assert res['summary']['tcp_syn_retries'] == 6
    assert res['summary']['synack_timeout_seconds'] == 31
    assert res['summary']['syn_timeout_seconds'] == 63
    assert res['summary']['syn_retrans'] == 1000
    assert res['summary']['syn_retrans_ratio_pct'] == 0.01

    # Case 2: Excessively high SYN-ACK retries (> 8) -> CRITICAL
    synack_f.write_text('9\n')
    res2 = mod.audit_synack_rto_guard(
        synack_retries_file=str(synack_f),
        syn_retries_file=str(syn_f),
        linear_timeouts_file=str(linear_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'CRITICAL'
    assert res2['summary']['healthy'] is False
    assert any('Excessively high SYN-ACK retries' in iss for iss in res2['summary']['issues'])
    synack_f.write_text('5\n')

    # Case 3: Very low retries (< 2) -> WARNING
    synack_f.write_text('1\n')
    res3 = mod.audit_synack_rto_guard(
        synack_retries_file=str(synack_f),
        syn_retries_file=str(syn_f),
        linear_timeouts_file=str(linear_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Very low SYN-ACK retries' in iss for iss in res3['summary']['issues'])

    # Case 4: Missing files fallback (fail-open)
    res4 = mod.audit_synack_rto_guard(
        synack_retries_file='/nonexistent/synack',
        syn_retries_file='/nonexistent/syn',
        linear_timeouts_file='/nonexistent/linear',
        netstat_file='/nonexistent/netstat',
    )
    assert res4['summary']['status'] == 'HEALTHY'
    assert res4['summary']['tcp_synack_retries'] == 5
    assert res4['summary']['syn_retrans'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 143 regression tests passed!"
