#!/usr/bin/env bash
# tests/fm-jev-rtt-guard.test.sh - Regression tests for Pattern 133 (TCP RTT Smoothing Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rtt-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rtt-guard.py"

echo "Running Pattern 133 regression tests..."

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
assert 'socket_stats' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_min_rtt_wlen' in s
assert 'tcp_frto' in s
assert 'spurious_rto_pct' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl, netstat, and ss outputs
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-rtt-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    min_rtt_f = d / 'tcp_min_rtt_wlen'
    frto_f = d / 'tcp_frto'
    cc_f = d / 'tcp_congestion_control'
    netstat_f = d / 'netstat'

    min_rtt_f.write_text('300\n')
    frto_f.write_text('2\n')
    cc_f.write_text('cubic\n')

    netstat_f.write_text('''TcpExt: TCPSpuriousRTOs TCPTimeouts TCPLossProbes TCPLossProbeRecovery TCPSpuriousRtxHostQueues
TcpExt: 10 1000 500 50 0
''')

    mock_ss = '''cubic wscale:13,10 rto:210 rtt:10.0/2.0 minrtt:5.0
cubic wscale:13,10 rto:210 rtt:20.0/3.0 minrtt:8.0
'''

    # Case 1: Nominal
    res = mod.audit_rtt(
        min_rtt_wlen_file=str(min_rtt_f),
        frto_file=str(frto_f),
        cc_file=str(cc_f),
        netstat_file=str(netstat_f),
        ss_sample_text=mock_ss,
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_min_rtt_wlen'] == 300
    assert res['summary']['tcp_frto'] == 2
    assert res['summary']['spurious_rto_pct'] == 1.0
    assert res['socket_stats']['total_sampled'] == 2
    assert res['socket_stats']['avg_rtt_ms'] == 15.0

    # Case 2: F-RTO disabled -> WARNING
    frto_f.write_text('0\n')
    res2 = mod.audit_rtt(
        min_rtt_wlen_file=str(min_rtt_f),
        frto_file=str(frto_f),
        cc_file=str(cc_f),
        netstat_file=str(netstat_f),
        ss_sample_text=mock_ss,
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Forward RTO' in iss for iss in res2['summary']['issues'])
    frto_f.write_text('2\n')

    # Case 3: High spurious RTO ratio -> WARNING
    netstat_f.write_text('''TcpExt: TCPSpuriousRTOs TCPTimeouts TCPLossProbes TCPLossProbeRecovery TCPSpuriousRtxHostQueues
TcpExt: 400 1000 500 50 0
''')
    res3 = mod.audit_rtt(
        min_rtt_wlen_file=str(min_rtt_f),
        frto_file=str(frto_f),
        cc_file=str(cc_f),
        netstat_file=str(netstat_f),
        ss_sample_text=mock_ss,
    )
    assert res3['summary']['status'] == 'WARNING'
    assert any('High spurious RTO ratio' in iss for iss in res3['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 133 regression tests passed!"
