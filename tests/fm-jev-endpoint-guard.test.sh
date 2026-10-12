#!/usr/bin/env bash
# tests/fm-jev-endpoint-guard.test.sh - Regression tests for Pattern 49 (Jev Multi-Agent Upstream Service Endpoint Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-endpoint-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-endpoint-guard.py"

echo "Running Pattern 49 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Python syntax check
python3 -m py_compile "$GUARD_PY"
echo "ok - python syntax clean"

# 3. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

# 4. JSON schema validation on audit with mock/local targets
json_out="$("$GUARD_SH" --endpoints https://api.github.com --json)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'endpoints' in data
assert isinstance(data['summary']['total_endpoints'], int)
assert isinstance(data['summary']['healthy'], bool)
for ep in data['endpoints']:
    assert 'endpoint' in ep
    assert 'type' in ep
    assert 'reachable' in ep
    assert 'latency_ms' in ep
"
echo "ok - json audit schema valid"

# 5. Check mode works on reachable target
"$GUARD_SH" --endpoints https://api.github.com --check
echo "ok - --check passes on reachable target"

# 6. Test unreachable target failure exit
if "$GUARD_SH" --endpoints "tcp://127.0.0.1:1" --timeout 0.2 --check >/dev/null 2>&1; then
    echo "FAILED: check mode should return non-zero on unreachable target"
    exit 1
else
    echo "ok - check mode exits non-zero on unreachable endpoint"
fi

# 7. Text output format
"$GUARD_SH" --endpoints https://api.github.com >/dev/null
echo "ok - text mode runs cleanly"

echo "ok - all Pattern 49 endpoint guard tests passed"
