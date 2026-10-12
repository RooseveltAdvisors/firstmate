#!/usr/bin/env bash
# tests/fm-jev-gro-batch-guard.test.sh - Regression tests for Pattern 283 (GroBatchGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-gro-batch-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-gro-batch-guard.py"

echo "Running Pattern 283 regression tests..."

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
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['gro_normal_batch'], int)
assert isinstance(data['dev_weight_rx_bias'], int)
assert isinstance(data['dev_weight_tx_bias'], int)
assert isinstance(data['netdev_tstamp_prequeue'], int)
assert isinstance(data['tstamp_allow_data'], int)
assert isinstance(data['message_burst'], int)
assert isinstance(data['message_cost'], int)
assert isinstance(data['softnet_processed'], int)
assert isinstance(data['softnet_dropped'], int)
assert isinstance(data['softnet_time_squeeze'], int)
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
mod = import_module('fm-jev-gro-batch-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    core_dir = d / 'core'
    core_dir.mkdir()
    (core_dir / 'gro_normal_batch').write_text('8\n')
    (core_dir / 'dev_weight_rx_bias').write_text('1\n')
    (core_dir / 'dev_weight_tx_bias').write_text('1\n')
    (core_dir / 'netdev_tstamp_prequeue').write_text('1\n')
    (core_dir / 'tstamp_allow_data').write_text('1\n')
    (core_dir / 'message_burst').write_text('10\n')
    (core_dir / 'message_cost').write_text('5\n')

    softnet_file = d / 'softnet_stat'
    softnet_file.write_text('000003e8 00000000 00000000 0 0 0 0 0\n')

    res = mod.audit_gro_batch_guard(core_dir=str(core_dir), softnet_file=str(softnet_file))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['gro_normal_batch'] == 8
    assert res['dev_weight_rx_bias'] == 1
    assert res['dev_weight_tx_bias'] == 1
    assert res['softnet_processed'] == 1000

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    core_dir = d / 'core'
    core_dir.mkdir()
    (core_dir / 'gro_normal_batch').write_text('0\n')
    (core_dir / 'dev_weight_rx_bias').write_text('0\n')
    (core_dir / 'dev_weight_tx_bias').write_text('32\n')
    (core_dir / 'netdev_tstamp_prequeue').write_text('1\n')
    (core_dir / 'tstamp_allow_data').write_text('1\n')
    (core_dir / 'message_burst').write_text('0\n')
    (core_dir / 'message_cost').write_text('0\n')

    res = mod.audit_gro_batch_guard(core_dir=str(core_dir), softnet_file=str(d / 'nonexistent'))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('gro_normal_batch is disabled' in iss for iss in res['issues'])
    assert any('Invalid dev_weight_rx_bias' in iss for iss in res['issues'])
    assert any('Excessive dev_weight_tx_bias' in iss for iss in res['issues'])
    assert any('Invalid message_cost' in iss for iss in res['issues'])
    assert any('Invalid message_burst' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 283 regression tests passed!"
