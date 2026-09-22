#!/usr/bin/env bash
# tests/fm-jev-hystart-guard.test.sh - Regression tests for Pattern 136 (TCP HyStart++ Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-hystart-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-hystart-guard.py"

echo "Running Pattern 136 regression tests..."

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
assert 'tcp_congestion_control' in s
assert 'total_hystart_detections' in s
assert 'total_cwnd_bounded_packets' in s
assert 'slow_start_retrans_pct' in s
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
mod = import_module('fm-jev-hystart-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    cc_f = d / 'tcp_congestion_control'
    ss_idle_f = d / 'tcp_slow_start_after_idle'
    netstat_f = d / 'netstat'

    cc_f.write_text('cubic\n')
    ss_idle_f.write_text('1\n')
    netstat_f.write_text('''TcpExt: TCPHystartTrainDetect TCPHystartTrainCwnd TCPHystartDelayDetect TCPHystartDelayCwnd TCPSlowStartRetrans TCPDelivered
TcpExt: 1000 50000 800 100000 50 1000000
''')

    # Case 1: Nominal healthy state
    res = mod.audit_hystart(
        cc_file=str(cc_f),
        ss_idle_file=str(ss_idle_f),
        netstat_file=str(netstat_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['total_hystart_detections'] == 1800
    assert res['summary']['total_cwnd_bounded_packets'] == 150000
    assert res['counters']['train_detect'] == 1000
    assert res['counters']['delay_detect'] == 800
    assert res['summary']['slow_start_retrans_pct'] == 2.78

    # Case 2: Elevated slow-start retransmissions (> 25% and > 500) -> WARNING
    netstat_f.write_text('''TcpExt: TCPHystartTrainDetect TCPHystartTrainCwnd TCPHystartDelayDetect TCPHystartDelayCwnd TCPSlowStartRetrans TCPDelivered
TcpExt: 1000 50000 800 100000 600 1000000
''')
    res2 = mod.audit_hystart(
        cc_file=str(cc_f),
        ss_idle_file=str(ss_idle_f),
        netstat_file=str(netstat_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert res2['summary']['healthy'] is False
    assert any('Elevated retransmission rate' in iss for iss in res2['summary']['issues'])
    assert any('tcp_slow_start_after_idle=0' in rec for rec in res2['summary']['recommendations'])

    # Case 3: Missing files fallback (fail-open)
    res3 = mod.audit_hystart(
        cc_file='/nonexistent/cc',
        ss_idle_file='/nonexistent/ss_idle',
        netstat_file='/nonexistent/netstat',
    )
    assert res3['summary']['status'] == 'HEALTHY'
    assert res3['summary']['tcp_congestion_control'] == 'cubic'
    assert res3['summary']['total_hystart_detections'] == 0
"
echo "ok - unit tests pass"

echo "All Pattern 136 regression tests passed!"
