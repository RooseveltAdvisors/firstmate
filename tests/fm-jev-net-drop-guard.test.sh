#!/usr/bin/env bash
# tests/fm-jev-net-drop-guard.test.sh - Regression tests for Pattern 60 (Jev Network Drop Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-net-drop-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-net-drop-guard.py"

echo "Running Pattern 60 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on audit
json_out="$("$GUARD_SH" --drop-warn 1.0 --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'interfaces' in data
assert isinstance(data['summary']['interfaces_count'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --drop-warn 1.0 >/dev/null
echo "ok - text mode runs cleanly"

# 6. Unit test on mock sysfs net structure
TEST_DIR="/tmp/test-net-drop-guard-$$"
mkdir -p "$TEST_DIR/eth0/statistics"
echo "up" > "$TEST_DIR/eth0/operstate"
echo "1500" > "$TEST_DIR/eth0/mtu"
echo "1000" > "$TEST_DIR/eth0/statistics/rx_packets"
echo "1000" > "$TEST_DIR/eth0/statistics/tx_packets"
echo "5" > "$TEST_DIR/eth0/statistics/rx_dropped"
echo "0" > "$TEST_DIR/eth0/statistics/tx_dropped"
echo "0" > "$TEST_DIR/eth0/statistics/rx_errors"
echo "0" > "$TEST_DIR/eth0/statistics/tx_errors"

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-net-drop-guard')

res = mod.audit_fleet_net_drops(
    sys_net_path='$TEST_DIR',
    drop_rate_warn=0.01  # 5 / 1005 = 0.00497 < 0.01 -> healthy
)
assert res['summary']['interfaces_count'] == 1
assert res['summary']['healthy'] is True

# Test warning when threshold is tighter
res_warn = mod.audit_fleet_net_drops(
    sys_net_path='$TEST_DIR',
    drop_rate_warn=0.001
)
assert res_warn['summary']['healthy'] is False
assert 'eth0' in res_warn['summary']['warning_interfaces']
"
rm -rf "$TEST_DIR"
echo "ok - unit audit on mock sysfs network passed"

echo "ok - all Pattern 60 network drop guard tests passed"
