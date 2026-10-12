#!/usr/bin/env bash
# tests/fm-jev-tcp-ssthresh-metrics-guard.test.sh - Regression tests for Pattern 299 (TcpSsthreshMetricsGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tcp-ssthresh-metrics-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tcp-ssthresh-metrics-guard.py"

echo "Running Pattern 299 regression tests..."

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
assert data['pattern'] == 299
assert data['name'] == 'tcp_ssthresh_metrics'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['tcp_no_ssthresh_metrics_save'], int)
assert isinstance(data['tcp_no_metrics_save'], int)
assert isinstance(data['tcp_slow_start_after_idle'], int)
assert isinstance(data['slow_start_retrans'], int)
assert isinstance(data['fast_retrans'], int)
assert isinstance(data['hystart_train_detect'], int)
assert isinstance(data['hystart_delay_detect'], int)
assert isinstance(data['tcp_timeouts'], int)
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
mod = import_module('fm-jev-tcp-ssthresh-metrics-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    f_ssthresh = d / 'tcp_no_ssthresh_metrics_save'
    f_ssthresh.write_text('1\n')
    f_metrics = d / 'tcp_no_metrics_save'
    f_metrics.write_text('0\n')
    f_idle = d / 'tcp_slow_start_after_idle'
    f_idle.write_text('1\n')

    netstat = d / 'netstat'
    netstat.write_text(
        'TcpExt: TCPSlowStartRetrans TCPFastRetrans TCPHystartTrainDetect TCPHystartTrainCwnd TCPHystartDelayDetect TCPHystartDelayCwnd TCPTimeouts\n'
        'TcpExt: 2000 30000 100 5000 80 4000 20\n'
    )

    res = mod.evaluate_tcp_ssthresh_metrics(
        no_ssthresh_save_file=str(f_ssthresh),
        no_metrics_save_file=str(f_metrics),
        ss_after_idle_file=str(f_idle),
        netstat_file=str(netstat),
        warn_slow_start_retrans_ratio=0.15,
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['tcp_no_ssthresh_metrics_save'] == 1
    assert res['tcp_no_metrics_save'] == 0
    assert res['tcp_slow_start_after_idle'] == 1
    assert res['slow_start_retrans'] == 2000
    assert res['fast_retrans'] == 30000
    assert len(res['issues']) == 0

    # Test error cases: invalid values and high slow start retrans ratio
    f_ssthresh.write_text('2\n')
    f_metrics.write_text('-1\n')
    netstat.write_text(
        'TcpExt: TCPSlowStartRetrans TCPFastRetrans TCPHystartTrainDetect TCPHystartTrainCwnd TCPHystartDelayDetect TCPHystartDelayCwnd TCPTimeouts\n'
        'TcpExt: 50000 10000 100 5000 80 4000 20\n'
    )

    res_err = mod.evaluate_tcp_ssthresh_metrics(
        no_ssthresh_save_file=str(f_ssthresh),
        no_metrics_save_file=str(f_metrics),
        ss_after_idle_file=str(f_idle),
        netstat_file=str(netstat),
        warn_slow_start_retrans_ratio=0.15,
    )
    assert res_err['healthy'] is False
    assert res_err['status'] == 'WARNING'
    assert any('Invalid net.ipv4.tcp_no_ssthresh_metrics_save' in iss for iss in res_err['issues'])
    assert any('Invalid net.ipv4.tcp_no_metrics_save' in iss for iss in res_err['issues'])
    assert any('High slow-start retransmission ratio' in iss for iss in res_err['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 299 tests passed successfully!"
