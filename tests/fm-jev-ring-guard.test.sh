#!/usr/bin/env bash
# tests/fm-jev-ring-guard.test.sh - Regression tests for Pattern 95 (NIC Ring Buffer Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-ring-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-ring-guard.py"

echo "Running Pattern 95 regression tests..."

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
assert isinstance(s['issues'], list)
for iface in data['interfaces']:
    assert 'name' in iface
    assert 'ring' in iface
    assert 'rx_dropped' in iface
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysfs interfaces and ethtool outputs
python3 -c "
import sys, tempfile, os
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-ring-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    net_root = Path(tmp_dir)
    eth0 = net_root / 'eth0'
    eth0.mkdir()
    (eth0 / 'operstate').write_text('up\n')
    stats = eth0 / 'statistics'
    stats.mkdir()
    (stats / 'rx_dropped').write_text('0\n')
    (stats / 'rx_fifo_errors').write_text('0\n')
    (stats / 'tx_dropped').write_text('0\n')
    (stats / 'tx_fifo_errors').write_text('0\n')

    mock_ethtool_nominal = '''
Pre-set maximums:
RX: 4096
TX: 4096
Current hardware settings:
RX: 4096
TX: 4096
'''
    # Case 1: Healthy at max capacity
    res = mod.audit_ring(
        net_dir=str(net_root),
        mock_ethtool_outputs={'eth0': mock_ethtool_nominal},
    )
    s = res['summary']
    assert s['status'] == 'HEALTHY'
    assert s['healthy'] is True
    assert res['interfaces'][0]['ring']['rx_at_max'] is True

    # Case 2: Undersized ring with packet drops triggers Warning
    mock_ethtool_undersized = '''
Pre-set maximums:
RX: 4096
TX: 4096
Current hardware settings:
RX: 256
TX: 256
'''
    (stats / 'rx_dropped').write_text('50\n')
    res_warn = mod.audit_ring(
        net_dir=str(net_root),
        mock_ethtool_outputs={'eth0': mock_ethtool_undersized},
    )
    assert res_warn['summary']['status'] == 'WARNING'
    assert any('undersized RX ring' in iss for iss in res_warn['summary']['issues'])
"
echo "ok - unit tests and mock audit pass"

echo "All Pattern 95 tests passed!"
