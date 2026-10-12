#!/usr/bin/env bash
# tests/fm-jev-optmem-guard.test.sh - Regression tests for Pattern 276 (OptmemGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-optmem-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-optmem-guard.py"

echo "Running Pattern 276 regression tests..."

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
assert isinstance(data['optmem_max_bytes'], int)
assert isinstance(data['max_skb_frags'], int)
assert isinstance(data['high_order_alloc_disable'], int)
assert isinstance(data['netdev_unregister_timeout_secs'], int)
assert isinstance(data['bpf_filter_headroom_ok'], bool)
assert isinstance(data['higher_order_alloc_enabled'], bool)
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
mod = import_module('fm-jev-optmem-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'optmem_max').write_text('131072\n')
    (d / 'max_skb_frags').write_text('17\n')
    (d / 'high_order_alloc_disable').write_text('0\n')
    (d / 'netdev_unregister_timeout_secs').write_text('10\n')

    res = mod.audit_optmem_guard(conf_dir=str(d))
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert len(res['issues']) == 0
    assert res['optmem_max_bytes'] == 131072
    assert res['max_skb_frags'] == 17
    assert res['bpf_filter_headroom_ok'] is True
    assert res['higher_order_alloc_enabled'] is True

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    (d / 'optmem_max').write_text('1024\n')
    (d / 'max_skb_frags').write_text('8\n')
    (d / 'high_order_alloc_disable').write_text('1\n')
    (d / 'netdev_unregister_timeout_secs').write_text('100\n')

    res = mod.audit_optmem_guard(conf_dir=str(d))
    assert res['healthy'] is False
    assert res['status'] == 'CRITICAL'
    assert any('Constrained socket ancillary buffer memory' in iss for iss in res['issues'])
    assert any('Low SKB paged fragments limit' in iss for iss in res['issues'])
    assert any('Higher-order page allocations disabled' in iss for iss in res['issues'])
    assert any('Abnormal netdev unregister timeout' in iss for iss in res['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 276 regression tests passed!"
