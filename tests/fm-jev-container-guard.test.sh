#!/usr/bin/env bash
# tests/fm-jev-container-guard.test.sh - Regression tests for Pattern 58 (Jev Container Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-container-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-container-guard.py"

echo "Running Pattern 58 regression tests..."

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
json_out="$("$GUARD_SH" --max-dead 200 --max-volumes 200 --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'dead_containers' in data
assert 'dangling_volumes' in data
assert isinstance(data['summary']['dead_containers_count'], int)
assert isinstance(data['summary']['dangling_volumes_count'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --max-dead 200 --max-volumes 200 >/dev/null
echo "ok - text mode runs cleanly"

# 6. Unit test on mock container parsing
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-container-guard')

# Verify detect_runtime returns valid string or None
rt = mod.detect_runtime()
assert rt in ('podman', 'docker', None)

# Verify summary calculation logic
res = mod.audit_fleet_containers(max_dead=100, max_volumes=100)
assert 'summary' in res
assert res['summary']['healthy'] is True
"
echo "ok - unit audit on runtime detection and summary logic passed"

echo "ok - all Pattern 58 container guard tests passed"
