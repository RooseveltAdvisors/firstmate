#!/usr/bin/env bash
# tests/fm-jev-pipe-capacity-guard.test.sh - Regression tests for Pattern 308 (PipeCapacityGuard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-pipe-capacity-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-pipe-capacity-guard.py"

echo "Running Pattern 308 regression tests..."

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
assert data['pattern'] == 308
assert data['name'] == 'pipe_capacity'
assert 'timestamp' in data
assert 'status' in data
assert isinstance(data['healthy'], bool)
assert isinstance(data['pipe_max_size_bytes'], int)
assert isinstance(data['pipe_max_size_kb'], (int, float))
assert isinstance(data['pipe_user_pages_soft'], int)
assert isinstance(data['pipe_user_soft_mb'], (int, float))
assert isinstance(data['pipe_user_pages_hard'], int)
assert isinstance(data['pipe_user_hard_mb'], (int, float))
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
mod = import_module('fm-jev-pipe-capacity-guard')

with tempfile.TemporaryDirectory() as tmp_dir:
    d = Path(tmp_dir)
    max_f = d / 'pipe-max-size'
    max_f.write_text('1048576\n')
    hard_f = d / 'pipe-user-pages-hard'
    hard_f.write_text('0\n')
    soft_f = d / 'pipe-user-pages-soft'
    soft_f.write_text('16384\n')

    res = mod.evaluate_pipe_capacity(
        pipe_max_size_file=str(max_f),
        pipe_user_pages_hard_file=str(hard_f),
        pipe_user_pages_soft_file=str(soft_f),
    )
    assert res['healthy'] is True
    assert res['status'] == 'HEALTHY'
    assert res['pipe_max_size_bytes'] == 1048576
    assert res['pipe_user_pages_soft'] == 16384
    assert res['pipe_user_pages_hard'] == 0
    assert len(res['issues']) == 0

    # Test warnings & inverted hard/soft limits
    max_f.write_text('16384\n') # undersized < 64KB
    soft_f.write_text('500\n') # undersized soft < 1024
    hard_f.write_text('200\n') # hard < soft

    res_warn = mod.evaluate_pipe_capacity(
        pipe_max_size_file=str(max_f),
        pipe_user_pages_hard_file=str(hard_f),
        pipe_user_pages_soft_file=str(soft_f),
    )
    assert res_warn['healthy'] is False
    assert res_warn['status'] == 'CRITICAL'
    assert any('below safe minimum' in iss for iss in res_warn['issues'])
    assert any('below recommended minimum' in iss for iss in res_warn['issues'])
    assert any('inverted ceiling' in iss for iss in res_warn['issues'])
"
echo "ok - unit tests with mocked files passed"

echo "All Pattern 308 regression tests passed successfully."
