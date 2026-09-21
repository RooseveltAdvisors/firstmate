#!/usr/bin/env bash
# tests/fm-jev-clock-guard.test.sh - Regression tests for Pattern 61 (Jev Clock Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-clock-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-clock-guard.py"

echo "Running Pattern 61 regression tests..."

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
json_out="$("$GUARD_SH" --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert isinstance(data['summary']['ntp_synchronized'], bool)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" >/dev/null
echo "ok - text mode runs cleanly"

# 6. Unit test on string parsing logic
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-clock-guard')

assert mod.parse_offset_ms('+2.001ms') == 2.001
assert mod.parse_offset_ms('-15.2us') == -0.0152
assert mod.parse_offset_ms('1.5s') == 1500.0
assert mod.parse_offset_ms('invalid') is None
"
echo "ok - unit audit on offset string parsing passed"

echo "ok - all Pattern 61 clock guard tests passed"
