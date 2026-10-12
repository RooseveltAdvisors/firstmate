#!/usr/bin/env bash
# tests/fm-jev-busy-poll-guard.test.sh - Regression tests for Pattern 318 (BusyPollGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-busy-poll-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-busy-poll-guard.py"

echo "Running Pattern 318 regression tests..."

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
assert data['pattern'] == 318
assert data['name'] == 'busy_poll'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_polling_healthy'], bool)
assert isinstance(data['busy_poll_us'], int)
assert isinstance(data['busy_read_us'], int)
assert isinstance(data['gro_normal_batch'], int)
assert isinstance(data['dev_weight'], int)
assert isinstance(data['busy_poll_rx_packets'], int)
assert isinstance(data['hp_acks'], int)
assert isinstance(data['issues'], list)
assert isinstance(data['recommendations'], list)
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
mod = import_module('fm-jev-busy-poll-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    bp_file = d / 'busy_poll'
    br_file = d / 'busy_read'
    gro_file = d / 'gro_normal_batch'
    dw_file = d / 'dev_weight'
    ns_file = d / 'netstat'

    bp_file.write_text('0\n')
    br_file.write_text('0\n')
    gro_file.write_text('8\n')
    dw_file.write_text('64\n')
    ns_file.write_text(
        'TcpExt: SyncookiesSent SyncookiesRecv BusyPollRxPackets TCPHPAcks\n'
        'TcpExt: 0 0 100 5000\n'
    )

    res = mod.evaluate_busy_poll(
        busy_poll_file=str(bp_file),
        busy_read_file=str(br_file),
        gro_batch_file=str(gro_file),
        dev_weight_file=str(dw_file),
        netstat_file=str(ns_file),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_polling_healthy'] is True
    assert res['busy_poll_us'] == 0
    assert res['busy_read_us'] == 0
    assert res['gro_normal_batch'] == 8
    assert res['dev_weight'] == 64
    assert res['busy_poll_rx_packets'] == 100
    assert res['hp_acks'] == 5000
    assert len(res['issues']) == 0

    # Test warning when busy_poll is elevated (e.g. 150)
    bp_file.write_text('150\n')
    res_warn = mod.evaluate_busy_poll(
        busy_poll_file=str(bp_file),
        busy_read_file=str(br_file),
        gro_batch_file=str(gro_file),
        dev_weight_file=str(dw_file),
        netstat_file=str(ns_file),
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert any('Elevated' in iss for iss in res_warn['issues'])

    # Test critical when busy_poll >= 500
    bp_file.write_text('500\n')
    res_crit = mod.evaluate_busy_poll(
        busy_poll_file=str(bp_file),
        busy_read_file=str(br_file),
        gro_batch_file=str(gro_file),
        dev_weight_file=str(dw_file),
        netstat_file=str(ns_file),
    )
    assert res_crit['healthy'] is False
    assert res_crit['status'] == 'CRITICAL'
    assert any('Critical' in iss for iss in res_crit['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 318 regression tests passed successfully."
