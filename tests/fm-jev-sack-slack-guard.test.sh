#!/usr/bin/env bash
# tests/fm-jev-sack-slack-guard.test.sh - Regression tests for Pattern 184 (TCP SACK Compression Slack Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-sack-slack-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-sack-slack-guard.py"

echo "Running Pattern 184 regression tests..."

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
assert 'tcp_comp_sack_slack_ns' in s
assert 'tcp_comp_sack_delay_ns' in s
assert 'tcp_comp_sack_nr' in s
assert 'ack_compressed' in s
assert 'delayed_acks' in s
assert 'delayed_ack_lost' in s
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
mod = import_module('fm-jev-sack-slack-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    slack_f = d / 'tcp_comp_sack_slack_ns'
    delay_f = d / 'tcp_comp_sack_delay_ns'
    nr_f = d / 'tcp_comp_sack_nr'
    netstat_f = d / 'netstat'

    slack_f.write_text('100000\n')
    delay_f.write_text('1000000\n')
    nr_f.write_text('44\n')
    netstat_f.write_text('''TcpExt: TCPAckCompressed DelayedACKs DelayedACKLost DelayedACKLocked
TcpExt: 10000 20000 500 10
''')

    # Case 1: Nominal
    res = mod.audit_sack_slack(
        slack_file=str(slack_f),
        delay_file=str(delay_f),
        nr_file=str(nr_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_comp_sack_slack_ns'] == 100000
    assert res['summary']['tcp_comp_sack_delay_ns'] == 1000000
    assert res['summary']['tcp_comp_sack_nr'] == 44
    assert res['summary']['ack_compressed'] == 10000

    # Case 2: Excessive slack -> WARNING
    slack_f.write_text('20000000\n')
    res2 = mod.audit_sack_slack(
        slack_file=str(slack_f),
        delay_file=str(delay_f),
        nr_file=str(nr_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('Excessive SACK compression slack window' in iss for iss in res2['summary']['issues'])

    # Case 3: Excessive delay -> WARNING
    slack_f.write_text('100000\n')
    delay_f.write_text('50000000\n')
    res3 = mod.audit_sack_slack(
        slack_file=str(slack_f),
        delay_file=str(delay_f),
        nr_file=str(nr_f),
        netstat_file=str(netstat_f),
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('Excessive SACK compression delay' in iss for iss in res3['summary']['issues'])

    # Case 4: SACK nr is 0 -> WARNING
    delay_f.write_text('1000000\n')
    nr_f.write_text('0\n')
    res4 = mod.audit_sack_slack(
        slack_file=str(slack_f),
        delay_file=str(delay_f),
        nr_file=str(nr_f),
        netstat_file=str(netstat_f),
    )
    assert res4['summary']['status'] == 'WARNING'
    assert any('compression disabled' in iss for iss in res4['summary']['issues'])
"
echo "ok - unit tests pass"

echo "Pattern 184 regression tests passed: 6/6 tests ok"
