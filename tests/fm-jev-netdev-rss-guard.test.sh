#!/usr/bin/env bash
# tests/fm-jev-netdev-rss-guard.test.sh - Regression tests for Pattern 300 (NetdevRssGuard) - Tercentenary Milestone
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-netdev-rss-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-netdev-rss-guard.py"

echo "Running Pattern 300 regression tests..."

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
assert data['pattern'] == 300
assert data['name'] == 'netdev_rss'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['rss_key_bytes'], int)
assert isinstance(data['is_driver_default_rss'], bool)
assert isinstance(data['mem_pcpu_rsv'], int)
assert isinstance(data['netdev_tstamp_prequeue'], int)
assert isinstance(data['warnings'], int)
assert isinstance(data['cpu_cores_audited'], int)
assert isinstance(data['softnet_processed'], int)
assert isinstance(data['softnet_dropped'], int)
assert isinstance(data['softnet_squeezed'], int)
assert isinstance(data['softnet_collision'], int)
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
mod = import_module('fm-jev-netdev-rss-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    f_rss = d / 'netdev_rss_key'
    # 52 zero bytes
    f_rss.write_text(':'.join(['00'] * 52) + '\n')
    f_pcpu = d / 'mem_pcpu_rsv'
    f_pcpu.write_text('256\n')
    f_tstamp = d / 'netdev_tstamp_prequeue'
    f_tstamp.write_text('1\n')
    f_warn = d / 'warnings'
    f_warn.write_text('0\n')

    softnet = d / 'softnet_stat'
    softnet.write_text(
        '00001000 00000000 00000005 00000000 00000000 00000000 00000000\n'
        '00002000 00000000 00000002 00000000 00000000 00000000 00000000\n'
    )

    res = mod.evaluate_netdev_rss(
        rss_key_file=str(f_rss),
        mem_pcpu_rsv_file=str(f_pcpu),
        tstamp_prequeue_file=str(f_tstamp),
        warnings_file=str(f_warn),
        softnet_stat_file=str(softnet),
        min_mem_pcpu_rsv=64,
        warn_dropped=100,
        warn_squeezed=50000,
        warn_collision=500,
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['rss_key_bytes'] == 52
    assert res['is_driver_default_rss'] is True
    assert res['mem_pcpu_rsv'] == 256
    assert res['netdev_tstamp_prequeue'] == 1
    assert res['warnings'] == 0
    assert res['cpu_cores_audited'] == 2
    assert res['softnet_processed'] == 0x3000
    assert res['softnet_dropped'] == 0
    assert res['softnet_squeezed'] == 7
    assert len(res['issues']) == 0

    # Test error cases: invalid values and high softnet drops/squeeze
    f_rss.write_text('00:11:22\n')
    f_pcpu.write_text('16\n')
    f_tstamp.write_text('3\n')
    f_warn.write_text('8\n')
    softnet.write_text(
        '00001000 00000100 00010000 00000400 00000000 00000000 00000000\n'
    )

    res_err = mod.evaluate_netdev_rss(
        rss_key_file=str(f_rss),
        mem_pcpu_rsv_file=str(f_pcpu),
        tstamp_prequeue_file=str(f_tstamp),
        warnings_file=str(f_warn),
        softnet_stat_file=str(softnet),
        min_mem_pcpu_rsv=64,
        warn_dropped=100,
        warn_squeezed=50000,
        warn_collision=500,
    )
    assert res_err['healthy'] is False
    assert res_err['status'] == 'WARNING'
    assert any('Invalid netdev_rss_key format' in iss for iss in res_err['issues'])
    assert any('Sub-optimal per-CPU network memory reservation' in iss for iss in res_err['issues'])
    assert any('Invalid net.core.netdev_tstamp_prequeue' in iss for iss in res_err['issues'])
    assert any('Invalid net.core.warnings' in iss for iss in res_err['issues'])
    assert any('Elevated softnet packet drops' in iss for iss in res_err['issues'])
    assert any('Elevated softnet budget squeeze events' in iss for iss in res_err['issues'])
    assert any('Elevated CPU transmit collisions' in iss for iss in res_err['issues'])
"
echo "ok - mocked unit tests pass"

echo "All Pattern 300 tests passed successfully!"
