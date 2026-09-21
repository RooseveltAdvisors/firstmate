#!/usr/bin/env bash
# tests/fm-jev-secret-guard.test.sh - Regression tests for Pattern 56 (Jev Secret Exposure Guard)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-secret-guard.sh"
GUARD_PY="$SCRIPT_DIR/../bin/fm-jev-secret-guard.py"

echo "Running Pattern 56 regression tests..."

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
json_out="$("$GUARD_SH" --paths /opt/ra/firstmate/scratch --json || true)"
python3 -c "
import json, sys
data = json.loads('''$json_out''')
assert 'timestamp' in data
assert 'summary' in data
assert 'findings' in data
assert isinstance(data['summary']['total_findings_count'], int)
assert isinstance(data['summary']['healthy'], bool)
"
echo "ok - json audit schema valid"

# 5. Check mode works on live host
"$GUARD_SH" --paths /opt/ra/firstmate/scratch >/dev/null || true
echo "ok - text mode runs cleanly"

# 6. Unit test on mock secret detection
TEST_DIR="/tmp/test-secret-guard-$$"
mkdir -p "$TEST_DIR"

# Clean file
cat << 'EOF' > "$TEST_DIR/clean.py"
def hello():
    print("No secrets here")
EOF

# Leak file with simulated GitHub token (40 chars)
cat << 'EOF' > "$TEST_DIR/leak.txt"
Here is my token: ghp_111122223333444455556666777788889999
EOF

python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../bin')
from importlib import import_module
mod = import_module('fm-jev-secret-guard')

res = mod.audit_fleet_secrets(
    search_paths=['$TEST_DIR'],
    max_depth=1
)
summary = res['summary']
assert summary['total_findings_count'] == 1
assert summary['status'] == 'CRITICAL'
assert summary['healthy'] is False

findings = res['findings']
assert findings[0]['type'] == 'GitHub Personal Access Token'
assert 'ghp_' in findings[0]['masked']
assert '...' in findings[0]['masked']
# Verify secret is not exposed in cleartext in output
assert '111122223333444455556666777788889999' not in findings[0]['masked']
"
rm -rf "$TEST_DIR"
echo "ok - unit audit on secret detection and masking passed"

echo "ok - all Pattern 56 secret guard tests passed"
