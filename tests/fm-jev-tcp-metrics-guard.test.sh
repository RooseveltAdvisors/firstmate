#!/usr/bin/env bash
# tests/fm-jev-tcp-metrics-guard.test.sh - Regression tests for Pattern 168 (TCP Metrics Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-tcp-metrics-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-tcp-metrics-guard.py"

echo "Running Pattern 168 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['issues'], list)
assert 'tcp_no_metrics_save' in s
assert 'tcp_no_ssthresh_metrics_save' in s
assert 'route_max_size' in s
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
mod = import_module('fm-jev-tcp-metrics-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    no_metrics_f = d / 'tcp_no_metrics_save'
    no_ssthresh_f = d / 'tcp_no_ssthresh_metrics_save'
    low_latency_f = d / 'tcp_low_latency'
    route_max_f = d / 'route_max_size'

    no_metrics_f.write_text('0\n')
    no_ssthresh_f.write_text('1\n')
    low_latency_f.write_text('0\n')
    route_max_f.write_text('2147483647\n')

    # Case 1: Nominal
    res = mod.audit_tcp_metrics(
        no_metrics_save_file=str(no_metrics_f),
        no_ssthresh_save_file=str(no_ssthresh_f),
        low_latency_file=str(low_latency_f),
        route_max_size_file=str(route_max_f),
    )
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['tcp_no_metrics_save'] == 0
    assert res['summary']['tcp_no_ssthresh_metrics_save'] == 1
    assert res['summary']['metrics_caching_active'] is True
    assert res['summary']['ssthresh_reset_active'] is True

    # Case 2: no_ssthresh_metrics_save == 0 -> WARNING
    no_ssthresh_f.write_text('0\n')
    res2 = mod.audit_tcp_metrics(
        no_metrics_save_file=str(no_metrics_f),
        no_ssthresh_save_file=str(no_ssthresh_f),
        low_latency_file=str(low_latency_f),
        route_max_size_file=str(route_max_f),
    )
    assert res2['summary']['status'] == 'WARNING'
    assert any('stale throttled ssthresh' in iss for iss in res2['summary']['issues'])
"
echo "ok - unit tests pass"

echo "All Pattern 168 regression tests passed!"
