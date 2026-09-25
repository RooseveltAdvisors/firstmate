#!/usr/bin/env bash
# tests/fm-jev-rps-rfs-guard.test.sh - Regression tests for Pattern 306 (RpsRfsGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-rps-rfs-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-rps-rfs-guard.py"

echo "Running Pattern 306 regression tests..."

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
assert data['pattern'] == 306
assert data['name'] == 'rps_rfs'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['rps_sock_flow_entries'], int)
assert isinstance(data['rps_default_mask'], str)
assert isinstance(data['flow_limit_cpu_bitmap'], str)
assert isinstance(data['gro_normal_batch'], int)
assert isinstance(data['netdev_tstamp_prequeue'], int)
assert isinstance(data['received_rps'], int)
assert isinstance(data['flow_limit_count'], int)
assert isinstance(data['cpu_count'], int)
assert isinstance(data['total_rx_queues'], int)
assert isinstance(data['rps_active_queues'], int)
assert isinstance(data['rfs_active_queues'], int)
assert isinstance(data['devices_scanned'], int)
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
mod = import_module('fm-jev-rps-rfs-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    rps_sock = d / 'rps_sock_flow_entries'
    rps_sock.write_text('32768\n')
    rps_def = d / 'rps_default_mask'
    rps_def.write_text('00000000\n')
    flow_limit = d / 'flow_limit_cpu_bitmap'
    flow_limit.write_text('00000000\n')
    gro = d / 'gro_normal_batch'
    gro.write_text('8\n')
    tstamp = d / 'netdev_tstamp_prequeue'
    tstamp.write_text('1\n')
    softnet = d / 'softnet_stat'
    softnet.write_text('00000000 00000000 00000000 00000000 00000005 0000000a\n')

    sysfs = d / 'sysfs'
    rx0 = sysfs / 'eth0' / 'queues' / 'rx-0'
    rx0.mkdir(parents=True)
    (rx0 / 'rps_cpus').write_text('00000001\n')
    (rx0 / 'rps_flow_cnt').write_text('4096\n')

    res = mod.evaluate_rps_rfs(
        rps_sock_flow_file=str(rps_sock),
        rps_default_mask_file=str(rps_def),
        flow_limit_cpu_file=str(flow_limit),
        gro_normal_batch_file=str(gro),
        netdev_tstamp_prequeue_file=str(tstamp),
        softnet_stat_file=str(softnet),
        sysfs_net_dir=str(sysfs),
        warn_flow_limit=100,
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['rps_sock_flow_entries'] == 32768
    assert res['gro_normal_batch'] == 8
    assert res['received_rps'] == 5
    assert res['flow_limit_count'] == 10
    assert res['cpu_count'] == 1
    assert res['total_rx_queues'] == 1
    assert res['rps_active_queues'] == 1
    assert res['rfs_active_queues'] == 1
    assert len(res['issues']) == 0

    # Test warnings: non-power-of-2 sock flow, gro <= 0, high flow limit
    rps_sock.write_text('1000\n')
    gro.write_text('0\n')
    softnet.write_text('00000000 00000000 00000000 00000000 00000000 000000ff\n')

    res_warn = mod.evaluate_rps_rfs(
        rps_sock_flow_file=str(rps_sock),
        rps_default_mask_file=str(rps_def),
        flow_limit_cpu_file=str(flow_limit),
        gro_normal_batch_file=str(gro),
        netdev_tstamp_prequeue_file=str(tstamp),
        softnet_stat_file=str(softnet),
        sysfs_net_dir=str(sysfs),
        warn_flow_limit=100,
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert any('GRO' in iss for iss in res_warn['issues'])
    assert any('power of 2' in iss for iss in res_warn['issues'])
    assert any('flow limit count' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 306 regression tests passed successfully."
