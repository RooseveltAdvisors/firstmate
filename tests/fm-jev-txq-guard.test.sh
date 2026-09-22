#!/usr/bin/env bash
# tests/fm-jev-txq-guard.test.sh - Regression tests for Pattern 91 (Host Network Transmit Queue Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-txq-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-txq-guard.py"

echo "Running Pattern 91 regression tests..."

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
assert 'interfaces' in data
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert 'interface_count' in s
assert 'total_tx_packets' in s
assert 'total_tx_dropped' in s
assert 'total_tx_fifo_errors' in s
assert isinstance(s['issues'], list)
for iface in data['interfaces']:
    assert 'name' in iface
    assert 'operstate' in iface
    assert 'tx_queue_len' in iface
    assert 'tx_packets' in iface
    assert 'tx_dropped' in iface
    assert 'tx_drop_pct' in iface
    assert 'bql_supported' in iface
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysfs interface trees
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-txq-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    net_root = Path(tmp_dir)
    eth0 = net_root / 'eth0'
    eth0.mkdir(parents=True)
    (eth0 / 'operstate').write_text('up\n')
    (eth0 / 'tx_queue_len').write_text('1000\n')

    stats0 = eth0 / 'statistics'
    stats0.mkdir()
    (stats0 / 'tx_packets').write_text('100000\n')
    (stats0 / 'tx_dropped').write_text('0\n')
    (stats0 / 'tx_fifo_errors').write_text('0\n')
    (stats0 / 'tx_errors').write_text('0\n')
    (stats0 / 'tx_carrier_errors').write_text('0\n')
    (stats0 / 'collisions').write_text('0\n')
    (stats0 / 'rx_packets').write_text('100000\n')
    (stats0 / 'rx_dropped').write_text('0\n')
    (stats0 / 'rx_fifo_errors').write_text('0\n')
    (stats0 / 'rx_over_errors').write_text('0\n')
    (stats0 / 'rx_errors').write_text('0\n')

    q_dir = eth0 / 'queues' / 'tx-0'
    bql_dir = q_dir / 'byte_queue_limits'
    bql_dir.mkdir(parents=True)
    (bql_dir / 'inflight').write_text('0\n')
    (bql_dir / 'limit').write_text('30000\n')
    (bql_dir / 'stall_cnt').write_text('0\n')
    (q_dir / 'tx_timeout').write_text('0\n')

    # Case 1: Healthy
    res = mod.audit_txq(net_dir=str(net_root))
    assert res['summary']['status'] == 'HEALTHY'
    assert res['summary']['healthy'] is True
    assert res['summary']['interface_count'] == 1
    assert res['interfaces'][0]['tx_drop_pct'] == 0.0

    # Case 2: Warning on elevated drops
    (stats0 / 'tx_dropped').write_text('100\n') # 100 / 100,100 = ~0.0999% > 0.05%
    res_warn = mod.audit_txq(net_dir=str(net_root))
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('elevated transmit drop' in iss for iss in res_warn['summary']['issues'])

    # Case 3: Critical on high drop rate (> 0.5%)
    (stats0 / 'tx_dropped').write_text('2000\n') # 2000 / 102,000 = ~1.96% > 0.5%
    res_crit = mod.audit_txq(net_dir=str(net_root))
    assert res_crit['summary']['status'] == 'CRITICAL'
    assert any('CRITICAL transmit drop' in iss for iss in res_crit['summary']['issues'])

    # Case 4: Overrun / FIFO buffer errors
    (stats0 / 'tx_dropped').write_text('0\n')
    (stats0 / 'tx_fifo_errors').write_text('5\n')
    res_fifo = mod.audit_txq(net_dir=str(net_root))
    assert res_fifo['summary']['status'] == 'WARNING'
    assert any('FIFO buffer overrun detected' in iss for iss in res_fifo['summary']['issues'])

    # Case 5: Driver transmit timeouts
    (stats0 / 'tx_fifo_errors').write_text('0\n')
    (q_dir / 'tx_timeout').write_text('3\n')
    res_timeout = mod.audit_txq(net_dir=str(net_root))
    assert res_timeout['summary']['status'] == 'WARNING'
    assert any('watchdog resets' in iss for iss in res_timeout['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 91 tests passed!"
