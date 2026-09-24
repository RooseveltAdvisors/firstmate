#!/usr/bin/env bash
# tests/fm-jev-napi-defer-guard.test.sh - Regression tests for Pattern 240 (NapiDeferGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-napi-defer-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-napi-defer-guard.py"

echo "Running Pattern 240 regression tests..."

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
s = data['summary']
assert 'status' in s
assert isinstance(s['healthy'], bool)
assert isinstance(s['total_interfaces'], int)
assert isinstance(s['up_interfaces'], int)
assert isinstance(s['deferred_interfaces_count'], int)
assert isinstance(s['deferred_interfaces'], list)
assert isinstance(s['gro_normal_batch'], int)
assert isinstance(s['dev_weight'], int)
assert isinstance(s['netdev_budget'], int)
assert isinstance(s['issues'], list)
assert isinstance(s['recommendation'], str)
assert 'interfaces' in data
assert 'core_sysctls' in data
"
echo "ok - json audit schema valid"

# 5. Text mode runs cleanly on host
"$GUARD_SH" >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit tests with mocked sysfs files
python3 -c "
import sys, tempfile
from pathlib import Path
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-napi-defer-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    net_d = d / 'net'
    core_d = d / 'core'
    net_d.mkdir()
    core_d.mkdir()

    # Nominal interface
    eth0 = net_d / 'eth0'
    eth0.mkdir()
    (eth0 / 'napi_defer_hard_irqs').write_text('1\n')
    (eth0 / 'gro_flush_timeout').write_text('20000\n')
    (eth0 / 'threaded').write_text('0\n')
    (eth0 / 'operstate').write_text('up\n')

    # Core sysctls
    (core_d / 'gro_normal_batch').write_text('8\n')
    (core_d / 'dev_weight').write_text('64\n')
    (core_d / 'dev_weight_rx_bias').write_text('1\n')
    (core_d / 'dev_weight_tx_bias').write_text('1\n')
    (core_d / 'netdev_budget').write_text('300\n')
    (core_d / 'netdev_budget_usecs').write_text('2000\n')
    (core_d / 'busy_poll').write_text('0\n')
    (core_d / 'busy_read').write_text('0\n')

    rep = mod.audit_napi_defer(sys_net_path=str(net_d), sys_core_path=str(core_d))
    assert rep['summary']['status'] == 'HEALTHY'
    assert rep['summary']['healthy'] is True
    assert rep['summary']['deferred_interfaces_count'] == 1
    assert len(rep['summary']['issues']) == 0

    # Warning: excessive deferral
    (eth0 / 'napi_defer_hard_irqs').write_text('25\n')
    (eth0 / 'gro_flush_timeout').write_text('500000\n')
    rep = mod.audit_napi_defer(sys_net_path=str(net_d), sys_core_path=str(core_d))
    assert rep['summary']['status'] == 'WARNING'
    assert rep['summary']['healthy'] is False
    assert any('napi_defer_hard_irqs=25' in iss for iss in rep['summary']['issues'])
    assert any('gro_flush_timeout=500000ns' in iss for iss in rep['summary']['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 240 regression tests passed successfully!"
