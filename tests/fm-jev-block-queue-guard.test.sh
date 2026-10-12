#!/usr/bin/env bash
# tests/fm-jev-block-queue-guard.test.sh - Regression tests for Pattern 320 (BlockQueueGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-block-queue-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-block-queue-guard.py"

echo "Running Pattern 320 regression tests..."

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
assert data['pattern'] == 320
assert data['name'] == 'block_queue'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['is_queue_healthy'], bool)
assert isinstance(data['devices_count'], int)
assert isinstance(data['device_names'], list)
assert isinstance(data['min_nr_requests_observed'], int)
assert isinstance(data['devices'], list)
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
mod = import_module('fm-jev-block-queue-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    nvme_q = d / 'nvme0n1' / 'queue'
    nvme_q.mkdir(parents=True)
    (nvme_q / 'scheduler').write_text('[none] mq-deadline\n')
    (nvme_q / 'nr_requests').write_text('1023\n')
    (nvme_q / 'read_ahead_kb').write_text('128\n')
    (nvme_q / 'rotational').write_text('0\n')

    sda_q = d / 'sda' / 'queue'
    sda_q.mkdir(parents=True)
    (sda_q / 'scheduler').write_text('none [mq-deadline]\n')
    (sda_q / 'nr_requests').write_text('64\n')
    (sda_q / 'read_ahead_kb').write_text('128\n')
    (sda_q / 'rotational').write_text('0\n')

    res = mod.evaluate_block_queue(block_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['is_queue_healthy'] is True
    assert res['devices_count'] == 2
    assert sorted(res['device_names']) == ['nvme0n1', 'sda']
    assert res['min_nr_requests_observed'] == 64
    assert len(res['issues']) == 0

    # Test warning for shallow queue depth
    (sda_q / 'nr_requests').write_text('32\n')
    res_warn = mod.evaluate_block_queue(block_dir=str(d), min_nr_requests=64)
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'WARNING'
    assert res_warn['is_queue_healthy'] is False
    assert any('Shallow' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 320 regression tests passed successfully."
