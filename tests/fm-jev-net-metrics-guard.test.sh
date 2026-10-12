#!/usr/bin/env bash
# tests/fm-jev-net-metrics-guard.test.sh - Regression tests for Pattern 117 (TCP Route Metrics Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-net-metrics-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-net-metrics-guard.py"

echo "Running Pattern 117 regression tests..."

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
assert 'total_cached_destinations' in s
assert 'stale_entries_over_24h' in s
assert 'max_cached_age_days' in s
assert 'clamped_ssthresh_count' in s
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysctl and ip tcp_metrics output files
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-net-metrics-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    save_file = d / 'tcp_no_metrics_save'
    metrics_file = d / 'tcp_metrics.txt'

    save_file.write_text('0\n')

    mock_metrics = '''18.238.80.117 age 1749783.402sec cwnd 10 rtt 7005us rttvar 9113us source 192.168.0.9
52.10.190.84 age 3600.000sec cwnd 10 rtt 74663us rttvar 74663us source 192.168.0.9
3.168.73.62 age 87000.000sec cwnd 10 rtt 4678us ssthresh 2 source 192.168.0.9
'''
    metrics_file.write_text(mock_metrics)

    # Case 1: Nominal
    res = mod.audit_net_metrics(
        no_metrics_save_file=str(save_file),
        metrics_file=str(metrics_file),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['total_cached_destinations'] == 3
    assert res['summary']['stale_entries_over_24h'] == 2 # 1749783s and 87000s
    assert res['summary']['clamped_ssthresh_count'] == 1 # ssthresh 2

    # Case 2: Excessive clamped ssthresh warning
    clamped_lines = '\n'.join([f'10.0.0.{i} age 100sec ssthresh 2' for i in range(60)])
    metrics_file.write_text(clamped_lines)
    res2 = mod.audit_net_metrics(
        no_metrics_save_file=str(save_file),
        metrics_file=str(metrics_file),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('Elevated clamped ssthresh' in iss for iss in res2['summary']['issues'])
"
echo "ok - mocked sysctl and tcp_metrics unit tests pass"

echo "All Pattern 117 tests passed successfully!"
